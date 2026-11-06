// tb_gather.sv -- unit check of mcu_gather. Drives the golden Y plane
// (vectors/img_<tag>_y.hex) and chroma plane (img_<tag>_c.hex) as back-
// pressured streams and compares the emitted block columns against
// vectors/gold_<tag>_blk.txt (comp + 64 natural-order coefficients; the
// block column at cycle d of a block = coefficient-matrix column, i.e.
// block[row][d] for rows 0..7).
// TAG via +TAG=<name> (flat64 default).
`timescale 1ns / 1ps
module tb_gather;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    reg cfg_valid = 0;
    reg [10:0] cfg_w = 0, cfg_h = 0;

    reg        y_valid = 0;
    reg        y_ready;
    reg [7:0]  y_data = 0;
    reg        y_sof = 0, y_eol = 0;
    reg        c_valid = 0;
    reg        c_ready;
    reg [7:0]  c_cb = 0, c_cr = 0;
    reg        c_sof = 0, c_eol = 0;

    wire        blk_valid;
    reg         blk_ready = 1;
    wire [63:0] blk_a;
    wire [2:0]  blk_comp;
    wire        blk_first, blk_last, blk_sof_frame;

    mcu_gather #(.MAX_W(1920)) dut (
        .clk(clk), .rst(rst),
        .cfg_valid(cfg_valid), .cfg_w(cfg_w), .cfg_h(cfg_h),
        .y_valid(y_valid), .y_ready(y_ready),
        .y_data(y_data), .y_sof(y_sof), .y_eol(y_eol),
        .c_valid(c_valid), .c_ready(c_ready),
        .c_cb(c_cb), .c_cr(c_cr), .c_sof(c_sof), .c_eol(c_eol),
        .blk_valid(blk_valid), .blk_ready(blk_ready),
        .blk_a(blk_a), .blk_comp(blk_comp),
        .blk_first(blk_first), .blk_last(blk_last),
        .blk_sof_frame(blk_sof_frame)
    );

    integer fd_y, fd_c, fd_blk, code, errors, sent_y, sent_c, blocks, rows;
    integer W, H;
    reg [7:0] yv, cv, cr;
    reg [15:0] cword;
    string tag, fname;
    integer rng_state;
    reg [8:0] cidx;            // chroma pixel index within the frame
    reg expect_sof;
    integer got_comp;
    reg [31:0] exp_pix [0:63];
    integer gi;
    reg [7:0] colbyte [0:7];
    reg done_flag;

    function [31:0] nextr;
    begin
        rng_state = (rng_state * 1103515245 + 12345) & 32'h7FFFFFFF;
        nextr = rng_state;
    end
    endfunction

    // compare one emitted block column: a[63-8r -: 8] = pixel[r][col]
    task check_block;
        input [63:0] a;
        integer r;
        reg [7:0] b;
        begin
            for (r = 0; r < 8; r = r + 1) begin
                b = a[63 - 8*r -: 8];
                if ({24'b0, b} !== exp_pix[r*8 + rows]) begin
                    errors = errors + 1;
                    if (errors < 10)
                        $display("ERR blk %0d row %0d col %0d: got %02x exp %0d",
                                 blocks-1, r, rows, b, exp_pix[r*8 + rows]);
                end
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("TAG=%s", tag)) tag = "flat64";
        rng_state = 32'hCAFEBABE;
        errors = 0; sent_y = 0; sent_c = 0; blocks = 0; rows = 0;

        fname = {"vectors/img_", tag, "_meta.txt"};
        fd_y = $fopen(fname, "r");
        if (fd_y == 0) begin
            $display("FATAL: no meta");
            $finish;
        end
        code = $fscanf(fd_y, "%d %d\n", W, H);
        $fclose(fd_y);

        rst = 1;
        repeat (4) @(posedge clk);
        #1 rst = 0;
        @(negedge clk);
        cfg_valid = 1; cfg_w = W[10:0]; cfg_h = H[10:0];
        @(negedge clk);
        cfg_valid = 0;

        // golden block file
        fname = {"vectors/gold_", tag, "_pix.txt"};
        fd_blk = $fopen(fname, "r");
        if (fd_blk == 0) begin
            $display("FATAL: no gold pix");
            $finish;
        end

        fork
            // input driver: Y + chroma concurrently with random gaps
            begin : drive
                fname = {"vectors/img_", tag, "_y.hex"};
                fd_y = $fopen(fname, "r");
                fname = {"vectors/img_", tag, "_c.hex"};
                fd_c = $fopen(fname, "r");
                if (fd_y == 0 || fd_c == 0) begin
                    $display("FATAL: plane files missing");
                    $finish;
                end
                cidx = 0;
                for (integer i = 0; i < W * H; i = i + 1) begin
                    code = $fscanf(fd_y, "%h\n", yv);
                    // chroma: one pixel per 2x2 Y block -- push at odd
                    // column of odd rows only (quarter rate)
                    if ((i % 2 == 1) && (((i / W) % 2) == 1)) begin
                        code = $fscanf(fd_c, "%h\n", cword);
                        cv = cword[15:8];
                        cr = cword[7:0];
                        // swap: file packs cb,cr -> cv=cb, cr=cr
                    end
                    // Y stream
                    @(negedge clk);
                    y_valid <= 1;
                    y_data <= yv;
                    y_sof <= (i == 0);
                    y_eol <= ((i + 1) % W == 0);
                    // chroma stream: same quarter-rate condition as the read
                    if ((i % 2 == 1) && (((i / W) % 2) == 1)) begin
                        c_valid <= 1;
                        c_cb <= cv;
                        c_cr <= cr;
                        c_sof <= (cidx == 0);
                        c_eol <= (((cidx + 1) % (W/2)) == 0);
                        cidx = cidx + 1;
                        if (cidx == (W/2) * (H/2)) cidx = 0;
                    end else begin
                        c_valid <= 0;
                    end
                    // wait for both handshakes
                    do @(posedge clk); while (!(y_valid && y_ready && (!c_valid || (c_valid && c_ready))));
                    if (c_valid && c_ready) begin
                        sent_c = sent_c + 1;
                        c_valid <= 0;
                    end
                    sent_y = sent_y + 1;
                end
                @(negedge clk);
                y_valid <= 0;
                c_valid <= 0;
            end
            // capture + compare
            begin : capture
                forever begin
                    @(posedge clk);
                    if (blk_valid && blk_ready) begin
                        if (blk_first) begin
                            if (blocks < 12)
                                $display("SEQ blk=%0d comp=%b first=%02x", blocks, blk_comp, blk_a[63:56]);
                            // load the golden pixel block for this comp
                            code = $fscanf(fd_blk, "%d", got_comp);
                            for (gi = 0; gi < 64; gi = gi + 1)
                                code = $fscanf(fd_blk, "%d", exp_pix[gi]);
                            if (blk_comp[1:0] !== got_comp[1:0]) begin
                                errors = errors + 1;
                                if (errors < 10)
                                    $display("ERR blk %0d comp got %0d exp %0d",
                                             blocks, blk_comp, got_comp);
                            end
                        end
                        check_block(blk_a);
                        rows = rows + 1;
                        if (rows == 8) begin
                            rows = 0;
                            blocks = blocks + 1;
                        end

                    end
                end
            end
            // backpressure
            begin : bp
                forever begin
                    @(negedge clk);
                    blk_ready <= (nextr() & 3) != 0;
                end
            end
            // watchdog: all blocks = (W/16)*(H/16)*6
            begin : wd
                repeat (4000000) @(posedge clk);
                errors = errors + 1000;
                $display("FATAL: watchdog; blocks=%0d exp %0d", blocks,
                         (W/16)*(H/16)*6);
                done_flag = 1;
            end
        join_none
        // wait until all blocks emitted
        begin : wait_all
            integer exp_blocks;
            exp_blocks = (W / 16) * (H / 16) * 6;
            while (blocks < exp_blocks) @(posedge clk);
            done_flag = 1;
        end
        wait (done_flag);
        disable fork;
        $fclose(fd_blk);

        $display("tb_gather tag=%0s: y=%0d c=%0d blocks=%0d errors=%0d -> %s",
                 tag, sent_y, sent_c, blocks, errors,
                 (errors == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
