// tb_fdct1d.sv -- unit check of fdct1d_llm against vectors/fdct1d_trace.txt
// (golden fdct1d, both pass modes). Self-checking with error counter.
`timescale 1ns / 1ps
module tb_fdct1d;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    reg en = 0, fp = 0;
    reg signed [15:0] x0, x1, x2, x3, x4, x5, x6, x7;
    wire signed [15:0] y0, y1, y2, y3, y4, y5, y6, y7;
    wire yv;

    fdct1d_llm dut (
        .clk(clk), .rst(rst), .en(en), .first_pass(fp),
        .x0(x0), .x1(x1), .x2(x2), .x3(x3),
        .x4(x4), .x5(x5), .x6(x6), .x7(x7),
        .y0(y0), .y1(y1), .y2(y2), .y3(y3),
        .y4(y4), .y5(y5), .y6(y6), .y7(y7), .yv(yv)
    );

    integer fd, code, errors, checked, pending;
    reg tfp;
    reg signed [14:0] tx0, tx1, tx2, tx3, tx4, tx5, tx6, tx7;
    reg signed [14:0] e0, e1, e2, e3, e4, e5, e6, e7;
    reg signed [14:0] p0, p1, p2, p3, p4, p5, p6, p7;

    task check_one;
        begin
            checked = checked + 1;
            if (y0 !== p0 || y1 !== p1 || y2 !== p2 || y3 !== p3 ||
                y4 !== p4 || y5 !== p5 || y6 !== p6 || y7 !== p7) begin
                errors = errors + 1;
                if (errors < 8)
                    $display("ERR t=%0t v%0d: got (%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d) exp (%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d)", $time,
                             checked-1, y0, y1, y2, y3, y4, y5, y6, y7,
                             p0, p1, p2, p3, p4, p5, p6, p7);
            end
        end
    endtask

    initial begin
        fd = $fopen("vectors/fdct1d_trace.txt", "r");
        if (fd == 0) begin
            $display("FATAL: no vectors/fdct1d_trace.txt");
            $finish;
        end
        errors = 0; checked = 0; pending = 0;
        rst = 1;
        repeat (4) @(posedge clk);
        #1 rst = 0;
        @(posedge clk);

        code = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d
",
                       tfp, tx0, tx1, tx2, tx3, tx4, tx5, tx6, tx7,
                       e0, e1, e2, e3, e4, e5, e6, e7);
        while (code == 17) begin
            @(negedge clk);
            en <= 1'b1;
            fp <= tfp;
            x0 <= tx0; x1 <= tx1; x2 <= tx2; x3 <= tx3;
            x4 <= tx4; x5 <= tx5; x6 <= tx6; x7 <= tx7;
            if (pending > 0)
                check_one;          // previously issued vector, 1-cycle latency
            p0 = e0; p1 = e1; p2 = e2; p3 = e3;
            p4 = e4; p5 = e5; p6 = e6; p7 = e7;
            pending = pending + 1;
            code = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d
",
                           tfp, tx0, tx1, tx2, tx3, tx4, tx5, tx6, tx7,
                           e0, e1, e2, e3, e4, e5, e6, e7);
        end

        // drain the final vector
        @(negedge clk);
        en <= 1'b0;
        @(posedge clk);
        #1;
        check_one;
        $display("tb_fdct1d: checked=%0d errors=%0d -> %s",
                 checked, errors, (errors == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
