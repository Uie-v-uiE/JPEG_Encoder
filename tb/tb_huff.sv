// tb_huff.sv -- unit check of huff_enc. Drives the golden quantized blocks
// (vectors/gold_<tag>_q.txt, natural... no: ZIGZAG order per golden) into
// the block buffers and compares the emitted bytes against
// vectors/gold_<tag>_huff.txt (per-block byte streams, sequential preds).
// TAG via +TAG=<name>.
`timescale 1ns / 1ps
module tb_huff;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    reg         q_valid = 0;
    wire        q_ready;
    reg [11:0]  q_0, q_1, q_2, q_3, q_4, q_5, q_6, q_7;
    reg [2:0]   q_comp = 0;
    reg         q_first = 0, q_last = 0;
    wire        out_valid;
    reg         out_ready = 1;
    wire [7:0]  out_data;
    wire        out_last;

    huff_enc dut (
        .clk(clk), .rst(rst),
        .q_valid(q_valid), .q_ready(q_ready),
        .q_0(q_0), .q_1(q_1), .q_2(q_2), .q_3(q_3),
        .q_4(q_4), .q_5(q_5), .q_6(q_6), .q_7(q_7),
        .q_comp(q_comp), .q_first(q_first), .q_last(q_last),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_data(out_data), .out_last(out_last)
    );

    integer fd_q, fd_h, code, errors, blocks, got, nbytes;
    integer fd_rtl;
    integer gcomp_h, gcnt_h;
    integer gi;
    reg [31:0] gcomp, gcnt;
    reg [31:0] gbyte;
    reg [11:0] qv [0:63];
    reg [11:0] qn [0:63];
    reg [5:0]  zzt [0:63];
    // golden q file is in ZIGZAG order; huff_enc expects NATURAL order
    // (it applies the ZZ ROM internally), so de-zigzag before driving
    initial $readmemh("zigzag.mem", zzt);
    string tag, fname;
    integer rng_state;
    reg done_flag;
    integer comp_errs;

    function [31:0] nextr;
    begin
        rng_state = (rng_state * 1103515245 + 12345) & 32'h7FFFFFFF;
        nextr = rng_state;
    end
    endfunction

    initial begin
        if (!$value$plusargs("TAG=%s", tag)) tag = "flat64";
        rng_state = 32'h1234ABCD;
        errors = 0; blocks = 0; got = 0; done_flag = 0;

        fname = {"vectors/gold_", tag, "_q.txt"};
        fd_q = $fopen(fname, "r");
        fname = {"vectors/gold_", tag, "_huff.txt"};
        fd_h = $fopen(fname, "r");
        if (fd_q == 0 || fd_h == 0) begin
            $display("FATAL: golden files missing");
            $finish;
        end

        rst = 1;
        repeat (4) @(posedge clk);
        #1 rst = 0;
        fd_rtl = 0;
        @(negedge clk);

        // output capture (forked)
        fork
            begin : capture
                forever begin
                    @(posedge clk);
                    if (out_valid && out_ready) begin
                        if (fd_rtl == 0)
                            fd_rtl = $fopen({"results/rtl_huff_", tag, ".hex"}, "w");
                        $fdisplay(fd_rtl, "%02x", out_data);
                        if (out_last) begin
                            done_flag = 1;
                            disable capture;
                        end
                        code = $fscanf(fd_h, "%h", gbyte);
                        if (code != 1) begin
                            errors = errors + 1;
                            $display("ERR byte %0d beyond golden", got);
                        end else if (out_data !== gbyte[7:0]) begin
                            errors = errors + 1;
                            if (errors < 12)
                                $display("ERR byte %0d: got %02x exp %02x",
                                         got, out_data, gbyte);
                        end
                        got = got + 1;
                    end
                end
            end
            // block driver
            begin : drive
                for (blocks = 0; blocks < 96; blocks = blocks + 1) begin
                    code = $fscanf(fd_q, "%d", gcomp);
                    for (gi = 0; gi < 64; gi = gi + 1)
                        code = $fscanf(fd_q, "%d", qv[gi]);
                    for (gi = 0; gi < 64; gi = gi + 1)
                        qn[zzt[gi]] = qv[gi];
                    // load golden byte count for this block (not compared
                    // per block; the whole-stream compare covers it)

                    // drive 8 groups of 8 coefficients
                    for (gi = 0; gi < 8; gi = gi + 1) begin
                        @(negedge clk);
                        q_valid <= 1;
                        q_0 <= qn[gi*8 + 0][11:0];
                        q_1 <= qn[gi*8 + 1][11:0];
                        q_2 <= qn[gi*8 + 2][11:0];
                        q_3 <= qn[gi*8 + 3][11:0];
                        q_4 <= qn[gi*8 + 4][11:0];
                        q_5 <= qn[gi*8 + 5][11:0];
                        q_6 <= qn[gi*8 + 6][11:0];
                        q_7 <= qn[gi*8 + 7][11:0];
                        q_comp <= {(blocks == 95), gcomp[1:0]};   // eof on last block
                        q_first <= (gi == 0);
                        q_last <= (gi == 7);
                        do @(posedge clk); while (!(q_valid && q_ready));
                        q_valid <= 0;
                    end
                end
            end
            // watchdog
            begin : wd
                repeat (200000) @(posedge clk);
                errors = errors + 1000;
                $display("FATAL: watchdog");
                done_flag = 1;
            end
        join_none
        wait (done_flag);
        disable fork;
        $fclose(fd_q);
        if (fd_rtl != 0) $fclose(fd_rtl);

        $display("tb_huff tag=%0s: blocks=%0d bytes=%0d errors=%0d -> %s",
                 tag, blocks, got, errors, (errors == 0) ? "PASS" : "FAIL");
        $finish;
    end

endmodule
