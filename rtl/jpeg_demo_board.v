// jpeg_demo_board.v — JPEG 编码器板级演示顶层(RK-XCKU5P-F)。
//   内置 64×64 RGB 图 ROM(flat64),上电自动:cfg → 4096 像素连续流入
//   jpeg_top → 熵编码字节流 → UART TX(115200-8N1, AC14)发到 PC;
//   LED0 = 编码+发送完成,LED1 = 时钟活性。
//   上板验证:串口助手 115200-8N1 收字节,与 vectors/gold_flat64_scan.hex
//   逐字节比对(功能正确性已由 tb_jpeg_top 4 图端到端逐字节保证)。
module jpeg_demo_board (
    input  wire       i_sys_clk_p,    // T24 差分 200 MHz
    input  wire       i_sys_clk_n,
    input  wire       i_sys_rst,      // K9 按键(高有效按下)
    output wire [3:0] o_led,          // H9/J9/G11/H11
    output wire       o_uart_tx       // AC14
);
    IBUFDS u_ibufds (
        .O(clk_raw), .I(i_sys_clk_p), .IB(i_sys_clk_n));

    // MMCM 200 → 100 MHz(gather/dct 组合链 ~6 ns,200 MHz 时序不闭合)
    wire clk_0, clk, clk_fb, clk_locked;
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"), .CLKIN1_PERIOD(5.000),
        .CLKFBOUT_MULT_F(5.000), .DIVCLK_DIVIDE(1), .CLKOUT0_DIVIDE_F(10.000),
        .STARTUP_WAIT("FALSE"))
    u_mmcm (
        .CLKIN1(clk_raw), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb),
        .CLKOUT0(clk_0), .LOCKED(clk_locked),
        .RST(1'b0), .PWRDWN(1'b0));
    BUFG u_bufg (.I(clk_0), .O(clk));

    reg [1:0] rsync;
    always @(posedge clk) rsync <= {rsync[0], i_sys_rst};
    wire rst = rsync[1] || !clk_locked;

    reg [24:0] blink_cnt;
    always @(posedge clk) blink_cnt <= blink_cnt + 1'b1;

    // ---------------- 图 ROM:64×64 RGB888 ----------------
    localparam NPIX = 4096;
    reg [23:0] rom [0:NPIX-1];
    initial $readmemh("jpeg_demo_rgb.mem", rom);
    reg [11:0] ridx;

    // ---------------- 编码器驱动 FSM ----------------
    localparam S_CFG = 2'd0, S_SEND = 2'd1, S_DRAIN = 2'd2, S_DONE = 2'd3;
    reg [1:0] st;
    wire       s_ready;
    reg        s_valid;
    reg        cfg_valid;
    wire       m_valid;
    wire [7:0] m_data;
    wire       m_last;
    reg        tx_we;
    reg [7:0]  tx_data;
    wire       tx_busy;
    reg [15:0] tx_cnt;

    always @(posedge clk) begin
        if (rst) begin
            st <= S_CFG; ridx <= 0; s_valid <= 0; cfg_valid <= 0;
            tx_we <= 0; tx_cnt <= 0;
        end else begin
            cfg_valid <= 1'b0;
            tx_we     <= 1'b0;
            case (st)
                S_CFG: begin
                    cfg_valid <= 1'b1;
                    ridx      <= 0;
                    st        <= S_SEND;
                end
                S_SEND: begin
                    s_valid <= 1'b1;         // 连续流(源 ROM 无 gap)
                    if (s_valid && s_ready) begin
                        ridx <= ridx + 1'b1;
                        if (ridx == NPIX - 1) begin
                            s_valid <= 1'b0;
                            st      <= S_DRAIN;
                        end
                    end
                end
                S_DRAIN: begin
                    if (m_valid && !tx_busy) begin
                        tx_we   <= 1'b1;
                        tx_data <= m_data;
                        tx_cnt  <= tx_cnt + 1'b1;
                        if (m_last) st <= S_DONE;
                    end
                end
                S_DONE: st <= S_DONE;
                default: st <= S_CFG;
            endcase
        end
    end

    // ROM 数据相位:发送拍固定给当前 ridx(源恒 ready 时逐拍推进)
    wire [23:0] px = rom[ridx];

    jpeg_top #(.MAX_W(1920)) u_jpeg (
        .clk(clk), .rst(rst),
        .cfg_valid(cfg_valid), .cfg_w(11'd64), .cfg_h(11'd64),
        .s_valid(s_valid), .s_ready(s_ready),
        .s_data(px), .s_user(ridx == 0), .s_last((ridx[5:0] == 6'd63)),
        .m_valid(m_valid), .m_ready(!tx_busy), .m_data(m_data), .m_last(m_last)
    );

    uart_tx #(.DIV(868)) u_uart (
        .clk(clk), .rst(rst), .we(tx_we), .data(tx_data),
        .tx(o_uart_tx), .busy(tx_busy)
    );

    reg done;
    always @(posedge clk) begin
        if (rst) done <= 1'b0;
        else if (st == S_DONE) done <= 1'b1;
    end

    assign o_led = {2'b00, blink_cnt[24], done};
endmodule
