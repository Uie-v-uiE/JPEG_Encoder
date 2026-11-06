// mcu_gather.v -- gathers raster Y / chroma streams into 16-line (Y) and
// 8-line (chroma) ping-pong windows, then emits JPEG MCU blocks in
// interleaved order (Y0,Y1,Y2,Y3,Cb,Cr per MCU, MCU raster order).
//
// Output granularity: one block COLUMN per cycle (8 pixels, rows 0..7 of
// that column) -- the DCT first pass runs along columns (separable
// transform, identical integer result to the golden row-first order).
// The address into the 8 row buffers is combinational, so the BRAM
// one-cycle latency lands each column exactly on its data cycle; all
// block-stream outputs are combinational and aligned.
//
// 9 cycles per block (1 warm + 8 data), 54 per MCU: 1080p60 needs ~26 MHz.
//
// Storage: 16 Y line BRAMs + 8 chroma line BRAMs (cb,cr pairs), two
// ping-pong sets. Input stalls only when a completed window waits for the
// emitter. Mirrors golden encode_frame() block order exactly.
module mcu_gather #(
    parameter integer MAX_W = 1920
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cfg_valid,
    input  wire [10:0] cfg_w,
    input  wire [10:0] cfg_h,
    input  wire        y_valid,
    output wire        y_ready,
    input  wire [7:0]  y_data,
    input  wire        y_sof,
    input  wire        y_eol,
    input  wire        c_valid,
    output wire        c_ready,
    input  wire [7:0]  c_cb,
    input  wire [7:0]  c_cr,
    input  wire        c_sof,
    input  wire        c_eol,
    output wire        blk_valid,
    input  wire        blk_ready,
    output wire [63:0] blk_a,       // 8 pixels of one block COLUMN, [63:56]=row 0
    output wire [2:0]  blk_comp,    // [1:0]=0/Y 1/Cb 2/Cr, [2]=frame end
    output wire        blk_first,
    output wire        blk_last,
    output wire        blk_sof_frame
);
    localparam integer YL = 16;
    localparam integer CL = 8;
    localparam LCW = mclog2(MAX_W);

    function integer mclog2(input integer d);
        integer v;
        begin
            v = 0;
            while ((1 << v) < d) v = v + 1;
            mclog2 = v;
        end
    endfunction

    // ------------------------------------------------------------- storage
    (* ram_style = "block" *)
    // 2-D flat arrays (set folded into the row index): Vivado 2025.2 has a
    // pathologically slow / unbounded elaboration path for 3-D packed RAMs
    // of this shape (ybuf 3-D stalled synthesis indefinitely, I-22)
    reg [7:0]  ybuf [0:2*YL-1][0:MAX_W-1];
    (* ram_style = "block" *)
    reg [15:0] cbuf [0:2*CL-1][0:MAX_W/2-1];

    // ---------------------------------------------------------- gather FSM
    reg [10:0] W, H;
    reg [3:0]  y_line;
    reg [LCW-1:0] y_x;
    reg [2:0]  c_line;
    reg [LCW-1:0] c_x;
    reg [10:0] mcu_row;
    reg        gpp;
    reg        cfg_seen;
    reg        pending_emit;

    // ----------------------------------------------------------- emit FSM
    reg        epp;
    reg        emit_active;
    reg [10:0] emit_mcu_row;
    reg [7:0]  emit_mcu_x;
    reg [2:0]  blk_idx;
    reg [2:0]  row_cnt;
    reg        phase;            // 0 = warm (bram read), 1 = data

    wire accept_y = y_valid && y_ready;
    wire accept_c = c_valid && c_ready;
    wire gather_complete = accept_y && (y_line == YL-1) && y_eol;
    // stall the input the moment a completed window awaits emission: the
    // input's next pixel would target the SAME (completed) set and corrupt
    // it. The old (epp == gpp) term was dead -- the pointers differ for the
    // whole emission -- so backpressure-stretched emissions lost windows
    // (I-18). pending_emit clears in start_emit, which also flips gpp to
    // the just-emptied set, so the input resumes into free storage.
    wire hold_input = !cfg_seen || pending_emit;
    assign y_ready = !hold_input;
    assign c_ready = !hold_input;

    // block geometry: blk_idx 0..3 = Y blocks (bx=idx[0], by=idx[1]),
    // 4 = Cb, 5 = Cr
    wire [1:0] bx = blk_idx[0];
    wire [1:0] by = (blk_idx[1:0] == 2'd2 || blk_idx[1:0] == 2'd3) ? 2'd1 : 2'd0;
    wire is_chroma = blk_idx[2];
    wire is_last_block_of_frame = (emit_mcu_row == H[10:4] - 1) &&
                                  (emit_mcu_x == W[10:4] - 1) &&
                                  (blk_idx == 3'd5);
    wire [LCW+4:0] y_base_full = {emit_mcu_x, 4'b0} + {3'b0, bx, 3'b0};
    wire [LCW-1:0] y_base = y_base_full[LCW-1:0];
    wire [LCW-1:0] c_base = {emit_mcu_x, 3'b0};     // 8 * mx (chroma plane)
    wire [3:0] y_row_base = {1'b0, by, 3'b0};       // 8 * by

    // block-stream handshake (comb outputs align with y_rd/c_rd)
    wire emit_step = blk_valid && blk_ready;

    // read addresses (combinational: warm presents base+0 so the BRAM
    // output register lands column 0 on the first data cycle)
    wire [LCW-1:0] y_raddr = (phase == 1'b0) ? y_base
                            : (y_base + row_cnt + 3'd1);
    wire [LCW-1:0] c_raddr = (phase == 1'b0) ? c_base
                            : (c_base + row_cnt + 3'd1);

    // synchronous reads: 8 row buffers at the shared column address
    reg [7:0]  y_rd [0:7];
    reg [15:0] c_rd [0:7];
    integer gi;
    // capture enable: warm cycle loads row 0; data cycles load the next
    // column only when the current one is accepted, so backpressure holds
    wire rd_en = (phase == 1'b0) || emit_step;
    always @(posedge clk) begin
        if (rd_en) begin
            for (gi = 0; gi < 8; gi = gi + 1) begin
                y_rd[gi] <= ybuf[{epp, y_row_base + gi[3:0]}][y_raddr];
                c_rd[gi] <= cbuf[{epp, gi[2:0]}][c_raddr];
            end
        end
    end

    // ------------------------------------------------------------- window
    task start_emit(input [10:0] row);
        begin
            emit_active <= 1'b1;
            epp <= gpp;
            emit_mcu_row <= row;
            emit_mcu_x <= 0;
            blk_idx <= 3'd0;
            row_cnt <= 3'd0;
            phase <= 1'b0;
            gpp <= !gpp;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            W <= 0; H <= 0; y_line <= 0; y_x <= 0; c_line <= 0; c_x <= 0;
            mcu_row <= 0; gpp <= 0; cfg_seen <= 0; pending_emit <= 0;
            epp <= 0; emit_active <= 0; emit_mcu_row <= 0; emit_mcu_x <= 0;
            blk_idx <= 0; row_cnt <= 0; phase <= 0;
        end else begin
            if (cfg_valid) begin
                W <= cfg_w;
                H <= cfg_h;
                y_line <= 0; c_line <= 0; mcu_row <= 0; gpp <= 0;
                epp <= 0; emit_active <= 0; pending_emit <= 0;
                cfg_seen <= 1'b1;
            end

            // ------------------------------------------------ gather writes
            if (accept_y && cfg_seen) begin
                ybuf[{gpp, y_line}][y_x] <= y_data;
                if (y_eol) begin
                    y_x <= 0;
                    if (y_line == YL-1) begin
                        y_line <= 0;
                        mcu_row <= mcu_row + 1'b1;
                    end else begin
                        y_line <= y_line + 1'b1;
                    end
                end else begin
                    y_x <= y_x + 1'b1;
                end
            end
            if (accept_c && cfg_seen) begin
                cbuf[{gpp, c_line}][c_x] <= {c_cb, c_cr};
                if (c_eol) begin
                    c_x <= 0;
                    c_line <= (c_line == CL-1) ? 3'd0 : c_line + 1'b1;
                end else begin
                    c_x <= c_x + 1'b1;
                end
            end

            // window completion / emission scheduling
            if (gather_complete && cfg_seen) begin
                if (!emit_active) begin
                    start_emit(mcu_row);
                end else begin
                    pending_emit <= 1'b1;
                end
            end

            // ------------------------------------------------ emit FSM
            if (emit_active) begin
                if (phase == 1'b0) begin
                    phase <= 1'b1;
                    row_cnt <= 3'd0;
                end else if (emit_step) begin
                    if (row_cnt == 3'd7) begin
                        row_cnt <= 3'd0;
                        phase <= 1'b0;
                        if (blk_idx == 3'd5) begin
                            blk_idx <= 3'd0;
                            if (emit_mcu_x == W[10:4] - 1) begin
                                emit_mcu_x <= 0;
                                if (emit_mcu_row == H[10:4] - 1) begin
                                    emit_active <= 1'b0;
                                end else if (pending_emit) begin
                                    pending_emit <= 1'b0;
                                    start_emit(emit_mcu_row + 1'b1);
                                end else begin
                                    emit_active <= 1'b0;   // no window ready
                                end
                            end else begin
                                emit_mcu_x <= emit_mcu_x + 1'b1;
                            end
                        end else begin
                            blk_idx <= blk_idx + 1'b1;
                        end
                    end else begin
                        row_cnt <= row_cnt + 1'b1;
                    end
                end
            end

            // emitter idle and a window is pending -> start it
            if (!emit_active && pending_emit && cfg_seen) begin
                pending_emit <= 1'b0;
                start_emit(emit_mcu_row + 1'b1);
            end
        end
    end

    // combinational block-stream outputs (aligned with y_rd/c_rd, which
    // already carry the BRAM one-cycle latency)
    assign blk_valid = emit_active && (phase == 1'b1);
    assign blk_comp = {is_last_block_of_frame,
                       is_chroma ? (blk_idx == 3'd4 ? 2'd1 : 2'd2) : 2'd0};
    assign blk_first = (row_cnt == 3'd0);
    assign blk_last  = (row_cnt == 3'd7);
    assign blk_a = !is_chroma ?
        {y_rd[0], y_rd[1], y_rd[2], y_rd[3], y_rd[4], y_rd[5], y_rd[6], y_rd[7]} :
        (blk_idx == 3'd4) ?
        {c_rd[0][15:8], c_rd[1][15:8], c_rd[2][15:8], c_rd[3][15:8],
         c_rd[4][15:8], c_rd[5][15:8], c_rd[6][15:8], c_rd[7][15:8]} :
        {c_rd[0][7:0], c_rd[1][7:0], c_rd[2][7:0], c_rd[3][7:0],
         c_rd[4][7:0], c_rd[5][7:0], c_rd[6][7:0], c_rd[7][7:0]};
    assign blk_sof_frame = blk_first && (blk_comp[1:0] == 2'd0) &&
                           (emit_mcu_row == 0);
endmodule
