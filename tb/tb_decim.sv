// tb_decim.sv -- unit check of decim420's chroma decimation. Drives the
// per-pixel Y/Cb/Cr raster (vectors/img_<tag>_pixcbcr.txt) with randomized
// input gaps + output backpressure, and compares the decimated chroma
// stream against vectors/gold_<tag>_decim.txt (cb/cr per 2x2, raster).
// TAG via +TAG=<name> (noise64 default). Self-checking.
`timescale 1ns / 1ps
module tb_decim;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    reg         s_valid = 0;
    wire        s_ready;
    reg [7:0]   s_y = 0, s_cb = 0, s_cr = 0;
    reg         s_sof = 0, s_eol = 0;
    wire        y_valid, cc_valid;
    reg         y_ready, cc_ready;
    wire [7:0]  y_data, cc_cb, cc_cr;
    wire        y_sof, y_eol, cc_sof, cc_eol;

    decim420 #(.MAX_W(1920)) dut (
        .clk(clk), .rst(rst),
        .cfg_valid(1'b0), .cfg_w(11'd64),
        .s_valid(s_valid), .s_ready(s_ready),
        .s_y(s_y), .s_cb(s_cb), .s_cr(s_cr),
        .s_sof(s_sof), .s_eol(s_eol),
        .y_valid(y_valid), .y_ready(y_ready),
        .y_data(y_data), .y_sof(y_sof), .y_eol(y_eol),
        .c_valid(cc_valid), .c_ready(cc_ready),
        .c_cb(cc_cb), .c_cr(cc_cr), .c_sof(cc_sof), .c_eol(cc_eol)
    );

    integer fd_in, fd_g, code, errors, sent, got, W, H;
    reg [7:0] yv, cbv, crv;
    reg [31:0] gcb, gcr;
    string tag, fname;
    integer rng_state;
    reg done_flag;
    integer exp_got;

    function [31:0] nextr;
    begin
        rng_state = (rng_state * 1103515245 + 12345) & 32'h7FFFFFFF;
        nextr = rng_state;
    end
    endfunction

    initial begin
        if (!$value$plusargs("TAG=%s", tag)) tag = "noise64";
        rng_state = 32'h5EED;
        errors = 0; sent = 0; got = 0; done_flag = 0;
        y_ready = 1; cc_ready = 1;

        fname = {"vectors/img_", tag, "_meta.txt"};
        fd_in = $fopen(fname, "r");
        if (fd_in == 0) begin
            $display("FATAL: no meta");
            $finish;
        end
        code = $fscanf(fd_in, "%d %d\n", W, H);
        $fclose(fd_in);
        exp_got = (W / 2) * (H / 2);

        fname = {"vectors/img_", tag, "_pixcbcr.txt"};
        fd_in = $fopen(fname, "r");
        fname = {"vectors/gold_", tag, "_decim.txt"};
        fd_g = $fopen(fname, "r");
        if (fd_in == 0 || fd_g == 0) begin
            $display("FATAL: input/golden missing");
            $finish;
        end

        rst = 1;
        repeat (4) @(posedge clk);
        #1 rst = 0;

        fork
            // input driver: raster order, randomized valid gaps
            begin : drive
                for (integer i = 0; i < W * H; i = i + 1) begin
                    code = $fscanf(fd_in, "%d %d %d\n", yv, cbv, crv);
                    if (code != 3) begin
                        errors = errors + 1000;
                        $display("FATAL: input short at %0d", i);
                        disable drive;
                    end
                    if ((nextr() & 3) == 0) begin
                        @(negedge clk);
                        s_valid <= 0;
                    end
                    @(negedge clk);
                    s_valid <= 1;
                    s_y <= yv; s_cb <= cbv; s_cr <= crv;
                    s_sof <= (i == 0);
                    s_eol <= ((i + 1) % W == 0);
                    do @(posedge clk); while (!(s_valid && s_ready));
                    sent = sent + 1;
                end
                @(negedge clk);
                s_valid <= 0;
            end
            // output backpressure on both streams
            begin : bp
                forever begin
                    @(negedge clk);
                    y_ready <= (nextr() & 3) != 0;
                    cc_ready <= (nextr() & 3) != 0;
                end
            end
            // chroma capture + compare
            begin : cap
                forever begin
                    @(posedge clk);
                    if (cc_valid && cc_ready) begin
                        code = $fscanf(fd_g, "%d %d\n", gcb, gcr);
                        if (code != 2) begin
                            errors = errors + 1;
                            $display("ERR chroma %0d beyond golden", got);
                        end else if (cc_cb !== gcb[7:0] || cc_cr !== gcr[7:0]) begin
                            errors = errors + 1;
                            if (errors < 12)
                                $display("ERR chroma %0d (x%0d y%0d): got (%0d,%0d) exp (%0d,%0d)",
                                         got, (got % (W/2)) * 2, (got / (W/2)) * 2,
                                         cc_cb, cc_cr, gcb, gcr);
                        end
                        got = got + 1;
                        if (got == exp_got) begin
                            done_flag = 1;
                            disable cap;
                        end
                    end
                end
            end
            // watchdog
            begin : wd
                repeat (500000) @(posedge clk);
                errors = errors + 1000;
                $display("FATAL: watchdog");
                done_flag = 1;
            end
        join_none
        wait (done_flag);
        disable fork;

        // golden must be fully consumed
        begin
            reg [31:0] ecb, ecr;
            code = $fscanf(fd_g, "%d %d\n", ecb, ecr);
            if (code == 2) begin
                errors = errors + 1;
                $display("ERR: golden has extra samples");
            end
        end
        $fclose(fd_in);
        $fclose(fd_g);

        $display("tb_decim tag=%0s: sent=%0d chroma=%0d errors=%0d -> %s",
                 tag, sent, got, errors, (errors == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
