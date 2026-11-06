// jpeg_top.v -- Baseline JPEG encoder core, RGB888 4:2:0 in, entropy bytes out.
// Zero vendor IP. Pipeline:
//   fifo2 -> rgb2ycbcr -> decim420 -> mcu_gather -> dct2d -> quant -> huff_enc
//
// Input stream: 24-bit RGB, raster order, s_user=frame start, s_last=line
// end. Frame config: cfg_valid pulse with cfg_w/cfg_h (multiples of 16, up
// to MAX_W) before the first pixel. Output: entropy-coded scan bytes
// (headers belong to the host); m_last marks the final byte of the scan.
// Throughput: 1 px/clock input; the entropy engine sustains ~1 block/64
// cycles (see huff_enc header + docs/DESIGN.md for the real-time envelope).
module jpeg_top #(
    parameter integer MAX_W = 1920
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cfg_valid,
    input  wire [10:0] cfg_w,
    input  wire [10:0] cfg_h,
    // AXI-Stream slave: RGB888
    input  wire        s_valid,
    output wire        s_ready,
    input  wire [23:0] s_data,
    input  wire        s_user,
    input  wire        s_last,
    // AXI-Stream master: entropy-coded bytes
    output wire        m_valid,
    input  wire        m_ready,
    output wire [7:0]  m_data,
    output wire        m_last
);
    // ------------------------------------------------ input 2-deep FIFO
    reg [23:0] f_d [0:3];
    reg        f_u [0:3];
    reg        f_l [0:3];
    reg [1:0]  f_wr, f_rd;
    reg [1:0]  f_cnt;
    wire f_head_v = (f_cnt != 0);
    wire f_pop;    // conv consumes the head (assigned below via its s_ready)
    assign s_ready = (f_cnt < 2'd3);
    wire accept = s_valid && s_ready;

    wire        p2_valid = f_head_v;
    wire [23:0] p2_data = f_d[f_rd];
    wire        p2_user = f_u[f_rd];
    wire        p2_last = f_l[f_rd];

    // conv input handshake: valid from FIFO head, ready from conv
    wire conv_ready;
    assign f_pop = f_head_v && conv_ready;

    // ------------------------------------------------------- rgb2ycbcr
    wire c_valid, c_ready, c_sof, c_eol;
    wire [7:0] c_y, c_cb, c_cr;
    rgb2ycbcr u_conv (
        .clk(clk), .rst(rst),
        .s_valid(p2_valid), .s_ready(conv_ready),
        .s_rgb(p2_data), .s_sof(p2_user), .s_eol(p2_last),
        .m_valid(c_valid), .m_ready(c_ready),
        .m_y(c_y), .m_cb(c_cb), .m_cr(c_cr),
        .m_sof(c_sof), .m_eol(c_eol)
    );

    always @(posedge clk) begin
        if (rst) begin
            f_wr <= 0; f_rd <= 0; f_cnt <= 0;
        end else begin
            if (accept) begin
                f_d[f_wr] <= s_data;
                f_u[f_wr] <= s_user;
                f_l[f_wr] <= s_last;
                f_wr <= f_wr + 1'b1;
            end
            if (f_pop)
                f_rd <= f_rd + 1'b1;
            case ({accept, f_pop})
                2'b10: f_cnt <= f_cnt + 1'b1;
                2'b01: f_cnt <= f_cnt - 1'b1;
                default: f_cnt <= f_cnt;
            endcase
        end
    end

    // -------------------------------------------------------- decim420
    wire y_valid, y_ready, y_sof, y_eol;
    wire [7:0] y_data;
    wire cc_valid, cc_ready, cc_sof, cc_eol;
    wire [7:0] cc_cb, cc_cr;
    decim420 #(.MAX_W(MAX_W)) u_decim (
        .clk(clk), .rst(rst),
        .cfg_valid(cfg_valid), .cfg_w(cfg_w),
        .s_valid(c_valid), .s_ready(c_ready),
        .s_y(c_y), .s_cb(c_cb), .s_cr(c_cr),
        .s_sof(c_sof), .s_eol(c_eol),
        .y_valid(y_valid), .y_ready(y_ready),
        .y_data(y_data), .y_sof(y_sof), .y_eol(y_eol),
        .c_valid(cc_valid), .c_ready(cc_ready),
        .c_cb(cc_cb), .c_cr(cc_cr), .c_sof(cc_sof), .c_eol(cc_eol)
    );

    // -------------------------------------------------------- mcu_gather
    wire blk_valid, blk_ready, blk_first, blk_last, blk_sof_frame;
    wire [63:0] blk_a;
    wire [2:0] blk_comp;
    mcu_gather #(.MAX_W(MAX_W)) u_gather (
        .clk(clk), .rst(rst),
        .cfg_valid(cfg_valid), .cfg_w(cfg_w), .cfg_h(cfg_h),
        .y_valid(y_valid), .y_ready(y_ready),
        .y_data(y_data), .y_sof(y_sof), .y_eol(y_eol),
        .c_valid(cc_valid), .c_ready(cc_ready),
        .c_cb(cc_cb), .c_cr(cc_cr), .c_sof(cc_sof), .c_eol(cc_eol),
        .blk_valid(blk_valid), .blk_ready(blk_ready),
        .blk_a(blk_a), .blk_comp(blk_comp),
        .blk_first(blk_first), .blk_last(blk_last),
        .blk_sof_frame(blk_sof_frame)
    );

    // ------------------------------------------------------------ dct2d
    wire coef_valid, coef_ready, coef_last;
    wire [14:0] coef_0, coef_1, coef_2, coef_3;
    wire [14:0] coef_4, coef_5, coef_6, coef_7;
    wire [2:0] coef_comp;
    dct2d u_dct (
        .clk(clk), .rst(rst),
        .blk_valid(blk_valid), .blk_ready(blk_ready),
        .blk_a(blk_a), .blk_comp(blk_comp),
        .blk_first(blk_first), .blk_last(blk_last),
        .coef_valid(coef_valid), .coef_ready(coef_ready),
        .coef_0(coef_0), .coef_1(coef_1), .coef_2(coef_2), .coef_3(coef_3),
        .coef_4(coef_4), .coef_5(coef_5), .coef_6(coef_6), .coef_7(coef_7),
        .coef_comp(coef_comp), .coef_last(coef_last)
    );

    // ------------------------------------------------------------ quant
    wire q_valid, q_ready, q_last, q_first;
    wire [11:0] q_0, q_1, q_2, q_3, q_4, q_5, q_6, q_7;
    wire [2:0] q_comp;
    quant u_quant (
        .clk(clk), .rst(rst),
        .coef_valid(coef_valid), .coef_ready(coef_ready),
        .coef_0(coef_0), .coef_1(coef_1), .coef_2(coef_2), .coef_3(coef_3),
        .coef_4(coef_4), .coef_5(coef_5), .coef_6(coef_6), .coef_7(coef_7),
        .coef_comp(coef_comp), .coef_first(1'b0), .coef_last(coef_last),
        .q_valid(q_valid), .q_ready(q_ready),
        .q_0(q_0), .q_1(q_1), .q_2(q_2), .q_3(q_3),
        .q_4(q_4), .q_5(q_5), .q_6(q_6), .q_7(q_7),
        .q_comp(q_comp), .q_first(q_first), .q_last(q_last)
    );

    // --------------------------------------------------------- huff_enc
    wire h_valid, h_ready, h_last;
    wire [7:0] h_data;
    huff_enc u_huff (
        .clk(clk), .rst(rst),
        .q_valid(q_valid), .q_ready(q_ready),
        .q_0(q_0), .q_1(q_1), .q_2(q_2), .q_3(q_3),
        .q_4(q_4), .q_5(q_5), .q_6(q_6), .q_7(q_7),
        .q_comp(q_comp), .q_first(q_first), .q_last(q_last),
        .out_valid(h_valid), .out_ready(h_ready),
        .out_data(h_data), .out_last(h_last)
    );

    // output: direct passthrough of the entropy byte stream
    assign m_valid = h_valid;
    assign m_data = h_data;
    assign m_last = h_last;
    assign h_ready = m_ready;
endmodule
