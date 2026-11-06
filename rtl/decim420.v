// decim420.v -- 4:2:0 chroma decimation with 2x2 box average.
// Input: full-rate Y + per-pixel Cb/Cr in raster order (sof/eol sidebands).
// Width W (multiple of 16, up to MAX_W) is parameterized (single mode).
//   Y:      3-stage delay pipeline (raster order preserved)
//   chroma: pair sums of row 2k are stored in a line buffer (W/2 x 18b);
//           on row 2k+1: out = (buf + pair) >> 2 == (a+b+c+d) >> 2.
//           A 4-deep FIFO decouples the half-rate chroma output; the input
//           stalls if a new result would overflow it.
// Chroma stream: W/2 pixels per row, H/2 rows; sof/eol mark each chroma row.
// Mirrors golden decim420(): unsigned (a+b+c+d) >> 2.
module decim420 #(
    parameter integer MAX_W = 1920
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       cfg_valid,
    input  wire [10:0] cfg_w,
    input  wire       s_valid,
    output wire       s_ready,
    input  wire [7:0] s_y,
    input  wire [7:0] s_cb,
    input  wire [7:0] s_cr,
    input  wire       s_sof,
    input  wire       s_eol,
    output reg        y_valid,
    input  wire       y_ready,
    output reg  [7:0] y_data,
    output reg        y_sof,
    output reg        y_eol,
    output wire       c_valid,
    input  wire       c_ready,
    output wire [7:0] c_cb,
    output wire [7:0] c_cr,
    output wire       c_sof,
    output wire       c_eol
);
    localparam integer CPW = MAX_W / 2;
    localparam LCW = clog2(MAX_W);

    function integer clog2(input integer d);
        integer v;
        begin
            v = 0;
            while ((1 << v) < d) v = v + 1;
            clog2 = v;
        end
    endfunction

    // ------------------------------------------------------------------ Y
    reg [7:0] yq0, yq1;
    reg vq0, vq1, sofq0, sofq1, eolq0, eolq1;

    // ------------------------------------------------------------- chroma
    reg [LCW-1:0] xcnt;      // pixel index in the line (0..W-1)
    reg [10:0] W;            // configured frame width (latched on cfg_valid)
    reg odd_row;             // 1 = second row of the vertical pair
    reg [8:0] cb_sum, cr_sum;
    reg [17:0] lbuf_dout;

    (* ram_style = "block" *)
    reg [17:0] lbuf [0:CPW-1];

    // pair sums (0..510)
    wire [8:0] pair_cb = s_cb + cb_sum;   // cb_sum holds the even-column byte
    wire [8:0] pair_cr = s_cr + cr_sum;

    // chroma result FIFO (4 deep), combinational head output
    reg [7:0] f_cb [0:3];
    reg [7:0] f_cr [0:3];
    reg f_sof [0:3];
    reg f_eol [0:3];
    reg [1:0] f_wr, f_rd;
    reg [2:0] f_cnt;
    wire f_full = (f_cnt == 3'd4);
    wire c_accept = c_valid && c_ready;
    wire go = !y_valid || y_ready;
    wire chroma_push = s_valid && go && xcnt[0] && odd_row && !s_sof;
    wire go_eff = go && !(chroma_push && f_full);
    assign s_ready = go_eff;

    assign c_valid = (f_cnt != 0);
    assign c_cb  = f_cb[f_rd];
    assign c_cr  = f_cr[f_rd];
    assign c_sof = f_sof[f_rd];
    assign c_eol = f_eol[f_rd];

    always @(posedge clk) begin
        if (rst) begin
            y_valid <= 0; y_sof <= 0; y_eol <= 0; y_data <= 0;
            vq0 <= 0; vq1 <= 0; sofq0 <= 0; sofq1 <= 0; eolq0 <= 0; eolq1 <= 0;
            yq0 <= 0; yq1 <= 0;
            xcnt <= 0; W <= 0; odd_row <= 0; cb_sum <= 0; cr_sum <= 0;
            f_wr <= 0; f_rd <= 0; f_cnt <= 0;
            lbuf_dout <= 0;
        end else begin
            // ---- Y delay (3 stages), advance when a pixel is accepted
            if (go_eff) begin
                y_valid <= vq1;
                y_sof   <= sofq1;
                y_eol   <= eolq1;
                y_data  <= yq1;
                vq1 <= vq0; sofq1 <= sofq0; eolq1 <= eolq0; yq1 <= yq0;
                vq0 <= s_valid; sofq0 <= s_valid && s_sof;
                eolq0 <= s_valid && s_eol; yq0 <= s_y;
            end

            // ---- frame width latch
            if (cfg_valid)
                W <= cfg_w;

            // ---- chroma accumulation
            // s_eol is handled as a TAIL (the line's last pixel is a normal
            // odd-column pair completion); an earlier `else if (s_eol)`
            // hijacked the branch and silently dropped every line-end pair
            // plus the eol flag (I-02 root cause).
            if (go_eff && s_valid) begin
                if (s_sof) begin
                    // the SOF pixel (0,0) is a normal even-column sample:
                    // store it AND consume its column slot (xcnt<=1, NOT 0
                    // -- resetting to 0 made pixel (0,1) look even-column,
                    // dropped (0,0) and shifted the whole first line's
                    // pairing by one pixel, I-17)
                    xcnt <= 1; odd_row <= 0;
                    cb_sum <= s_cb;
                    cr_sum <= s_cr;
                end else begin
                    if (xcnt[0] == 1'b0) begin
                        cb_sum <= s_cb;
                        cr_sum <= s_cr;
                        // preload the line-buffer read for THIS pair: the
                        // registered BRAM output lands exactly on the
                        // odd-column completion cycle. (rd_addr_r used to
                        // freeze at the even row's LAST pair and served that
                        // stale entry to every push of the odd row, I-16)
                        lbuf_dout <= lbuf[xcnt[LCW-1:1]];
                    end else begin
                        cb_sum <= 0;
                        cr_sum <= 0;
                        if (!odd_row) begin
                            // write the pair AND issue its read address: the
                            // BRAM dout lands exactly on the row-2 odd column
                            lbuf[xcnt[LCW-1:1]] <= {pair_cb, pair_cr};
                        end else begin
                            // 10-bit intermediate: two 9-bit pair sums reach
                            // 644 which overflows a 9-bit add
                            f_cb[f_wr] <= ({1'b0, lbuf_dout[17:9]} + {1'b0, pair_cb}) >> 2;
                            f_cr[f_wr] <= ({1'b0, lbuf_dout[8:0]} + {1'b0, pair_cr}) >> 2;
                            f_sof[f_wr] <= (xcnt == 1);
                            f_eol[f_wr] <= (xcnt == W - 1);
                            f_wr <= f_wr + 1'b1;
                        end
                    end
                    if (s_eol) begin
                        xcnt <= 0;
                        odd_row <= !odd_row;
                    end else begin
                        xcnt <= xcnt + 1'b1;
                    end
                end
            end

            // FIFO pointers
            if (chroma_push && !f_full)
                f_cnt <= f_cnt + 1'b1;
            if (c_accept)
                f_cnt <= f_cnt - 1'b1;
            if (chroma_push && !f_full && c_accept)
                f_cnt <= f_cnt;             // simultaneous push+pop: net zero
            if (c_accept)
                f_rd <= f_rd + 1'b1;
            if (chroma_push && !f_full)
                f_wr <= f_wr + 1'b1;

        end
    end
endmodule
