// uart_tx.v — 最小 8N1 发送器(波特率 = clk/6 分频系数参数)
module uart_tx #(
    parameter integer DIV = 1736              // 200 MHz / 115200 ≈ 1736
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       we,                     // 1 拍脉冲:装载 data 发送
    input  wire [7:0] data,
    output reg        tx,                     // 空闲 = 1
    output wire       busy
);
    localparam CW = $clog2(DIV);
    reg [CW-1:0] baud_cnt;
    reg [3:0]    bitidx;                       // 起始 + 8 数据 + 停止
    reg [7:0]    shreg;
    reg          running;

    assign busy = running;
    always @(posedge clk) begin
        if (rst) begin
            running <= 1'b0; tx <= 1'b1; bitidx <= 0; baud_cnt <= 0;
        end else if (!running) begin
            tx <= 1'b1;
            if (we) begin
                running <= 1'b1; shreg <= data; bitidx <= 0; baud_cnt <= 0; tx <= 1'b0;
            end
        end else begin
            if (baud_cnt == DIV - 1) begin
                baud_cnt <= 0;
                if (bitidx == 4'd8) begin
                    running <= 1'b0; tx <= 1'b1;      // 8 数据位毕 → 停止位
                end else begin
                    tx <= shreg[0];                    // LSB 先
                    shreg <= shreg >> 1;
                    bitidx <= bitidx + 1'b1;
                end
            end else begin
                baud_cnt <= baud_cnt + 1'b1;
            end
        end
    end
endmodule
