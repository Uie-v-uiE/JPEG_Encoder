// dct2d.v -- 2-D integer FDCT (jfdctint), column-first pass order.
// Input: block-column stream from mcu_gather (blk_a[63:56] = block row 0).
// Level shift (-128) applied at pass 1.
//
// Slot pipeline (2 slots): FREE -> FILL (8 columns) -> FULL
//   -> P1 (8 cycles, 1-D along columns) -> P1DONE
//   -> P2 (8 cycles, 1-D along rows, coefficients streamed) -> FREE.
// One fdct1d_llm core is shared (pass 1 priority). Issue-time registers
// (drain_slot / drain_col / drain_row) capture which slot/index each core
// result belongs to; the drain (1 cycle later) writes the p1 RAM or the
// coefficient stream. Pass-2 results occupy the output registers until
// accepted, gating further core runs.
// Coefficients leave in natural order, 8 per clock, 15-bit signed.
module dct2d (
    input  wire        clk,
    input  wire        rst,
    input  wire        blk_valid,
    output wire        blk_ready,
    input  wire [63:0] blk_a,
    input  wire [2:0]  blk_comp,
    input  wire        blk_first,
    input  wire        blk_last,
    output wire        coef_valid,
    input  wire        coef_ready,
    output wire [14:0] coef_0,
    output wire [14:0] coef_1,
    output wire [14:0] coef_2,
    output wire [14:0] coef_3,
    output wire [14:0] coef_4,
    output wire [14:0] coef_5,
    output wire [14:0] coef_6,
    output wire [14:0] coef_7,
    output wire [2:0]  coef_comp,
    output wire        coef_last
);
    localparam S_FREE = 3'd0, S_FILL = 3'd1, S_FULL = 3'd2,
               S_P1 = 3'd3, S_P1D = 3'd4, S_P2 = 3'd5;

    reg [2:0] state [0:1];
    reg [2:0] comp [0:1];
    reg [2:0] fill_col [0:1];
    reg [7:0] inbuf [0:1][0:7][0:7];
    reg signed [14:0] p1ram [0:1][0:7][0:7];

    reg       fill_sel;      // slot filling now
    reg       p1_sel;        // slot in pass 1
    reg       p2_sel;        // slot in pass 2
    reg       p1_active;     // pass 1 in flight (8-cycle run)
    reg       p2_active;     // pass 2 in flight (8-cycle run)
    reg [2:0] p1_icol;       // pass-1 issue column (0..7)
    reg [2:0] p2_irow;       // pass-2 issue row (0..7)
    reg       core_out_is_p1;
    reg       core_slot;     // slot of the in-flight core result
    reg [2:0] core_idx;      // column (p1) or row (p2) of the in-flight result
    reg [2:0] core_comp;     // comp of the in-flight pass-2 result ([2]=eof;
                             // a 2-bit decl truncated the frame-end bit and
                             // the huff engine never flushed the final byte)

    // ------------------------------------------- coefficient output FIFO
    // 2-deep skid: a core drain lands ONE CYCLE after its issue, and the
    // consumer's ready may deassert in that cycle (it accepted the previous
    // group and its pipeline filled). A 1-deep register lost one group per
    // block to exactly that race (I-14); depth 2 absorbs it.
    reg [14:0] cf_d   [0:1][0:7];
    reg [2:0]  cf_comp[0:1];
    reg        cf_last[0:1];
    reg        cf_wr, cf_rd;
    reg [1:0]  cf_cnt;
    wire core_yv;   // (driven by the fdct1d instance below)
    wire coef_push = core_yv && !core_out_is_p1;
    wire coef_pop  = coef_valid && coef_ready;
    assign coef_valid = (cf_cnt != 2'd0);
    assign coef_0   = cf_d[cf_rd][0];
    assign coef_1   = cf_d[cf_rd][1];
    assign coef_2   = cf_d[cf_rd][2];
    assign coef_3   = cf_d[cf_rd][3];
    assign coef_4   = cf_d[cf_rd][4];
    assign coef_5   = cf_d[cf_rd][5];
    assign coef_6   = cf_d[cf_rd][6];
    assign coef_7   = cf_d[cf_rd][7];
    assign coef_comp = cf_comp[cf_rd];
    assign coef_last = cf_last[cf_rd];

    // core gate: the push caused by this issue lands next cycle, so the
    // FIFO must have room AFTER this cycle's pop AND this cycle's own
    // concurrent drain push (back-to-back P2 rows drain+issue on the same
    // edge -- ignoring that let the count reach 3 in a 2-deep array and
    // the third push overwrote an unread group, I-19)
    wire [2:0] cf_cnt_proj = {1'b0, cf_cnt}
                             + (coef_push ? 3'd1 : 3'd0)
                             - (coef_pop  ? 3'd1 : 3'd0);
    wire core_gate = (cf_cnt_proj < 3'd2);

    wire accept = blk_valid && blk_ready;
    wire fill_done = accept && blk_last;

    wire fill_free = (state[0] == S_FREE) || (state[0] == S_FILL) ||
                     (state[1] == S_FREE) || (state[1] == S_FILL);
    assign blk_ready = fill_free;

    // target slot for this accept: continue FILL, else first FREE
    wire [1:0] fill_sel_now = (state[fill_sel] == S_FILL) ? fill_sel :
                              (state[0] == S_FREE || state[0] == S_FILL) ? 1'b0 : 1'b1;
    // column index for THIS accept: a FREE->FILL transition writes column 0
    wire [2:0] fill_fcol = (state[fill_sel_now] == S_FILL) ?
                           fill_col[fill_sel_now] : 3'd0;


    // pass 1 runs (start on a FULL slot, continue while S_P1); pass 2
    // likewise for P1D/P2. The issue transitions the slot state so the core
    // advances one column/row per cycle.
    // p1_active/p2_active: a multi-cycle pass is in flight; the issue stops
    // after column/row 7 (the drain clears the flag), preventing a spurious
    // 9th issue from the one-cycle-late state transition.
    // p1_more/p2_more: "this pass still has a run to issue". Must use the
    // pass's OWN progress register (p1_icol/p2_irow, which wrap to 0 after
    // the 8th run) -- core_idx is SHARED between the passes and belongs to
    // whichever result is in flight, so gating on it deadlocks the OTHER
    // pass after a preemption (I-12) and lets a ghost en-cycle compute a
    // bogus result that leaks into the coefficient stream (I-10 follow-up).
    wire p1_more = !p1_active || (p1_icol != 3'd0);
    wire p2_more = !p2_active || (p2_irow != 3'd0);
    wire p1_any = p1_more && (p1_active ||
                  ((state[0] == S_FULL) || (state[1] == S_FULL)));
    wire p2_any = p2_more && (p2_active ||
                  ((state[0] == S_P1D) || (state[1] == S_P1D)));
    wire run_p1 = p1_any && core_gate;
    wire run_p2 = !run_p1 && p2_any && core_gate;
    wire core_en = run_p1 || run_p2;

    // slot selection for the core this cycle
    wire [1:0] p1_use = p1_active ? p1_sel :
                        (state[0] == S_FULL ? 1'b0 : 1'b1);
    wire [2:0] p1_col = p1_active ? p1_icol : 3'd0;
    wire [1:0] p2_use = p2_active ? p2_sel :
                        (state[0] == S_P1D ? 1'b0 : 1'b1);
    wire [2:0] p2_row = p2_active ? p2_irow : 3'd0;

    // pass-1 inputs: column p1_col of the FULL slot, level shifted
    // (16-bit wires match the core port width exactly -- a 15-bit connection
    // leaves bit 15 undriven and poisons the arithmetic with X)
    wire signed [15:0] px0 = {1'b0, inbuf[p1_use][0][p1_col]} - 16'sd128;
    wire signed [15:0] px1 = {1'b0, inbuf[p1_use][1][p1_col]} - 16'sd128;
    wire signed [15:0] px2 = {1'b0, inbuf[p1_use][2][p1_col]} - 16'sd128;
    wire signed [15:0] px3 = {1'b0, inbuf[p1_use][3][p1_col]} - 16'sd128;
    wire signed [15:0] px4 = {1'b0, inbuf[p1_use][4][p1_col]} - 16'sd128;
    wire signed [15:0] px5 = {1'b0, inbuf[p1_use][5][p1_col]} - 16'sd128;
    wire signed [15:0] px6 = {1'b0, inbuf[p1_use][6][p1_col]} - 16'sd128;
    wire signed [15:0] px7 = {1'b0, inbuf[p1_use][7][p1_col]} - 16'sd128;

    // pass-2 inputs: row p2_row of the P1DONE slot
    wire signed [15:0] qx0 = p1ram[p2_use][0][p2_row];
    wire signed [15:0] qx1 = p1ram[p2_use][1][p2_row];
    wire signed [15:0] qx2 = p1ram[p2_use][2][p2_row];
    wire signed [15:0] qx3 = p1ram[p2_use][3][p2_row];
    wire signed [15:0] qx4 = p1ram[p2_use][4][p2_row];
    wire signed [15:0] qx5 = p1ram[p2_use][5][p2_row];
    wire signed [15:0] qx6 = p1ram[p2_use][6][p2_row];
    wire signed [15:0] qx7 = p1ram[p2_use][7][p2_row];

    wire signed [15:0] core_y0, core_y1, core_y2, core_y3;
    wire signed [15:0] core_y4, core_y5, core_y6, core_y7;

    fdct1d_llm u_core (
        .clk(clk), .rst(rst), .en(core_en), .first_pass(run_p1),
        .x0(run_p1 ? px0 : qx0), .x1(run_p1 ? px1 : qx1),
        .x2(run_p1 ? px2 : qx2), .x3(run_p1 ? px3 : qx3),
        .x4(run_p1 ? px4 : qx4), .x5(run_p1 ? px5 : qx5),
        .x6(run_p1 ? px6 : qx6), .x7(run_p1 ? px7 : qx7),
        .y0(core_y0), .y1(core_y1), .y2(core_y2), .y3(core_y3),
        .y4(core_y4), .y5(core_y5), .y6(core_y6), .y7(core_y7),
        .yv(core_yv)
    );

    integer si, ri, ci;

    always @(posedge clk) begin
        if (rst) begin
            for (si = 0; si < 2; si = si + 1) begin
                state[si] <= S_FREE;
                comp[si] <= 3'd0;
                fill_col[si] <= 3'd0;
            end
            fill_sel <= 0; p1_sel <= 0; p2_sel <= 0;
            p1_active <= 0; p2_active <= 0;
            p1_icol <= 0; p2_irow <= 0;
            core_out_is_p1 <= 0; core_slot <= 0; core_idx <= 0; core_comp <= 0;
            cf_wr <= 0; cf_rd <= 0; cf_cnt <= 0;
        end else begin
            // ---------------- input fill ----------------
            if (accept) begin
                inbuf[fill_sel_now][0][fill_fcol] <= blk_a[63:56];
                inbuf[fill_sel_now][1][fill_fcol] <= blk_a[55:48];
                inbuf[fill_sel_now][2][fill_fcol] <= blk_a[47:40];
                inbuf[fill_sel_now][3][fill_fcol] <= blk_a[39:32];
                inbuf[fill_sel_now][4][fill_fcol] <= blk_a[31:24];
                inbuf[fill_sel_now][5][fill_fcol] <= blk_a[23:16];
                inbuf[fill_sel_now][6][fill_fcol] <= blk_a[15:8];
                inbuf[fill_sel_now][7][fill_fcol] <= blk_a[7:0];
                fill_sel <= fill_sel_now;
                if (state[fill_sel_now] != S_FILL) begin
                    fill_col[fill_sel_now] <= 3'd1;   // column 0 written now
                    state[fill_sel_now] <= S_FILL;
                end else if (fill_done) begin
                    state[fill_sel_now] <= S_FULL;
                    comp[fill_sel_now] <= blk_comp;
                    fill_col[fill_sel_now] <= 3'd0;
                end else begin
                    fill_col[fill_sel_now] <= fill_col[fill_sel_now] + 1'b1;
                end
            end

            // ---------------- core issue ----------------
            if (run_p1) begin
                if (!p1_active) begin
                    p1_sel <= p1_use;          // start: column 0
                    p1_active <= 1'b1;
                    core_out_is_p1 <= 1'b1;
                    core_slot <= p1_use;
                    core_idx <= 3'd0;
                    state[p1_use] <= S_P1;
                    p1_icol <= 3'd1;
                end else begin
                    core_out_is_p1 <= 1'b1;
                    core_slot <= p1_sel;
                    core_idx <= p1_icol;
                    p1_icol <= p1_icol + 1'b1;
                end
            end else if (run_p2) begin
                if (!p2_active) begin
                    p2_sel <= p2_use;          // start: row 0
                    p2_active <= 1'b1;
                    core_out_is_p1 <= 1'b0;
                    core_slot <= p2_use;
                    core_idx <= 3'd0;
                    core_comp <= comp[p2_use];
                    state[p2_use] <= S_P2;
                    p2_irow <= 3'd1;
                end else begin
                    core_out_is_p1 <= 1'b0;
                    core_slot <= p2_sel;
                    core_idx <= p2_irow;
                    core_comp <= comp[p2_sel];
                    p2_irow <= p2_irow + 1'b1;
                end
            end

            // ---------------- core drain (1 cycle after issue) ----------
            if (core_yv) begin
                if (core_out_is_p1) begin
                    p1ram[core_slot][core_idx][0] <= core_y0;
                    p1ram[core_slot][core_idx][1] <= core_y1;
                    p1ram[core_slot][core_idx][2] <= core_y2;
                    p1ram[core_slot][core_idx][3] <= core_y3;
                    p1ram[core_slot][core_idx][4] <= core_y4;
                    p1ram[core_slot][core_idx][5] <= core_y5;
                    p1ram[core_slot][core_idx][6] <= core_y6;
                    p1ram[core_slot][core_idx][7] <= core_y7;
                    if (core_idx == 3'd7) begin
                        state[core_slot] <= S_P1D;
                        p1_active <= 1'b0;
                    end
                end else begin
                    // push into the 2-deep output FIFO (single count write
                    // point: push - pop; the consumer pops from the head)
                    cf_d[cf_wr][0] <= core_y0; cf_d[cf_wr][1] <= core_y1;
                    cf_d[cf_wr][2] <= core_y2; cf_d[cf_wr][3] <= core_y3;
                    cf_d[cf_wr][4] <= core_y4; cf_d[cf_wr][5] <= core_y5;
                    cf_d[cf_wr][6] <= core_y6; cf_d[cf_wr][7] <= core_y7;
                    cf_comp[cf_wr] <= core_comp;
                    cf_last[cf_wr] <= (core_idx == 3'd7);
                    // toggle: a [1:0] +1 counter walks to 2/3 and reads
                    // out-of-bounds X entries (same bug class as huff's
                    // wslot, I-08) -- rows 3/7 of every block became X and
                    // q_last never reached huff (I-15)
                    cf_wr <= ~cf_wr;
                    if (core_idx == 3'd7) begin
                        state[core_slot] <= S_FREE;
                        p2_active <= 1'b0;
                    end
                end
            end
            // FIFO count: single write point (push on drain, pop on accept)
            cf_cnt <= cf_cnt + (coef_push ? 2'd1 : 2'd0)
                              - (coef_pop ? 2'd1 : 2'd0);
            if (coef_pop)
                cf_rd <= ~cf_rd;
        end
    end
endmodule
