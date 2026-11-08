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
    (* mark_debug = "true" *) wire dbg_locked = clk_locked;
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"), .CLKIN1_PERIOD(5.000),
        .CLKFBOUT_MULT_F(5.000), .DIVCLK_DIVIDE(1), .CLKOUT0_DIVIDE_F(10.000),
        .STARTUP_WAIT("FALSE"))
    u_mmcm (
        .CLKIN1(clk_raw), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb),
        .CLKOUT0(clk_0), .LOCKED(clk_locked),
        .RST(1'b0), .PWRDWN(1'b0));
    BUFG u_bufg (.I(clk_0), .O(clk));

    // 复位不依赖 K9 按键:官方参考设计同样只用 locked(板上按键极性
    // 未在原理图外确认,若 K9 空闲为高则设计永处复位、串口零输出,I-36)。
    // 按键仅留作端口(未用)。
    wire [1:0] rsync = 2'b00;
    // locked 后再延迟 128 拍放行(稳妥化:确保 MMCM/JTAG 重配置后所有逻辑稳定)
    reg [6:0] lock_cnt;
    always @(posedge clk) begin
        if (!clk_locked) lock_cnt <= 7'd0;
        else if (lock_cnt != 7'd127) lock_cnt <= lock_cnt + 1'b1;
    end
    wire rst = !clk_locked || (lock_cnt != 7'd127);

    reg [24:0] blink_cnt;
    always @(posedge clk) blink_cnt <= blink_cnt + 1'b1;

    // ---------------- 图 ROM:64×64 RGB888 ----------------
    localparam NPIX = 4096;
    reg [23:0] rom [0:NPIX-1];
    initial $readmemh("jpeg_demo_rgb.mem", rom);
    (* mark_debug = "true" *) reg [11:0] ridx;

    // ---------------- 编码器驱动 FSM ----------------
    localparam S_CFG = 2'd0, S_SEND = 2'd1, S_DRAIN = 2'd2, S_DONE = 2'd3;
    reg [1:0] st;
(* mark_debug = "true" *) wire       s_ready;
(* mark_debug = "true" *) reg        s_valid;
(* mark_debug = "true" *) reg        cfg_valid;
(* mark_debug = "true" *) wire       m_valid;
(* mark_debug = "true" *) wire [7:0] m_data;
(* mark_debug = "true" *) wire       m_last;
(* mark_debug = "true" *) reg        tx_we;
    reg [7:0]  tx_data;
    wire       tx_busy;
(* mark_debug = "true" *) reg [15:0] tx_cnt;

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

    wire [3:0] jpeg_diag;
    jpeg_top #(.MAX_W(1920)) u_jpeg (
        .clk(clk), .rst(rst),
        .cfg_valid(cfg_valid), .cfg_w(11'd64), .cfg_h(11'd64),
        .diag(jpeg_diag),
        .s_valid(s_valid), .s_ready(s_ready),
        .s_data(px), .s_user(ridx == 0), .s_last((ridx[5:0] == 6'd63)),
        .m_valid(m_valid), .m_ready(!tx_busy), .m_data(m_data), .m_last(m_last)
    );


    // dut_cfg_seen 由层次引用赋值(综合支持 read-only 层次探测)
    // 见 jpeg_top 新增诊断输出端口
    uart_tx #(.DIV(868)) u_uart (
        .clk(clk), .rst(rst), .we(tx_we), .data(tx_data),
        .tx(o_uart_tx), .busy(tx_busy)
    );

(* mark_debug = "true" *) reg done;
    always @(posedge clk) begin
        if (rst) done <= 1'b0;
        else if (st == S_DONE) done <= 1'b1;
    end

    // LED 诊断映射(I-25 板上卡死定位):
    // LED3 = 活性闪烁;LED2 = gather cfg_seen(配置已收);LED1 = !hold(收数使能);
    // LED0 = accept_y 翻转累计(像素被 gather 接受的活动)
    assign o_led = {blink_cnt[24], jpeg_diag[2], jpeg_diag[1], jpeg_diag[0]};
endmodule
