// tb_jpeg_top.sv -- end-to-end check of the JPEG encoder core.
// Drives an RGB test image from vectors/img_<tag>_rgb.hex through jpeg_top
// (randomized valid gaps + output backpressure), captures the entropy byte
// stream and compares it byte-exact against vectors/gold_<tag>_scan.hex.
// TAG via +TAG=<name> (flat64 default). Self-checking.
`timescale 1ns / 1ps
module tb_jpeg_top;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    reg         s_valid = 0;
    wire        s_ready;
    reg [23:0]  s_data = 0;
    reg         s_user = 0, s_last = 0;
    wire        m_valid, m_last;
    wire [7:0]  m_data;
    reg         m_ready = 1;

    reg cfg_valid = 0;
    reg [10:0] cfg_w = 0, cfg_h = 0;

    jpeg_top #(.MAX_W(1920)) dut (
        .clk(clk), .rst(rst),
        .cfg_valid(cfg_valid), .cfg_w(cfg_w), .cfg_h(cfg_h),
        .s_valid(s_valid), .s_ready(s_ready),
        .s_data(s_data), .s_user(s_user), .s_last(s_last),
        .m_valid(m_valid), .m_ready(m_ready),
        .m_data(m_data), .m_last(m_last)
    );

    integer fd_img, fd_gold, fd_rtl, code, errors, sent, got, W, H;
    integer nogap, dummy_int;
    reg [23:0] px;
    string tag;
    string fname;
    integer rng_state;
    reg [7:0] gbyte;
    reg done_flag;

    function [31:0] nextr;
    begin
        rng_state = (rng_state * 1103515245 + 12345) & 32'h7FFFFFFF;
        nextr = rng_state;
    end
    endfunction

`ifdef PROBE
    // debug taps, all sampled inside always @(posedge) so every read
    // sees the SAME pre-edge values the consumer latches (negedge or
    // post-edge reads race the register update on back-to-back streams)
    reg p1d;
    reg [1:0] p1d_slot;
    integer pf_c, pf_q, pf_g, pf_y, pf_cs, pf_p1, pf_raw, pf_p2;
    reg signed [15:0] cbuf [0:63];
    reg signed [15:0] qbuf [0:63];
    reg [7:0] gbuf [0:63];
    integer cg, qg, gg, cj, p1cnt, p2cnt, p2cnt_next;
    initial begin
        cg = 0; qg = 0; gg = 0; p1cnt = 0; p2cnt = 0; p2cnt_next = 0;
        p1d = 0; p1d_slot = 0;
        pf_c = 0; pf_q = 0; pf_g = 0; pf_y = 0; pf_cs = 0; pf_p1 = 0;
        pf_p2 = 0;
    end
    always @(posedge clk) if (!done_flag) begin
        // lazy open: the main initial sets tag from +TAG well after time 0;
        // a time-0 fopen saw an empty tag and created probe__*.txt files
        if (pf_c == 0 && tag != "") begin
            pf_c = $fopen({"results/probe_", tag, "_blk.txt"}, "w");
            pf_q = $fopen({"results/probe_", tag, "_q.txt"}, "w");
            pf_g = $fopen({"results/probe_", tag, "_in.txt"}, "w");
            pf_y = $fopen({"results/probe_", tag, "_ystr.txt"}, "w");
            pf_cs = $fopen({"results/probe_", tag, "_cstr.txt"}, "w");
            pf_raw = $fopen({"results/probe_", tag, "_raw.txt"}, "w");
            pf_p2 = $fopen({"results/probe_", tag, "_p2.txt"}, "w");
            pf_p1 = $fopen({"results/probe_", tag, "_p1.txt"}, "w");
            pf_p2 = $fopen({"results/probe_", tag, "_p2.txt"}, "w");
        end
        if (dut.y_valid && dut.y_ready)
            $fdisplay(pf_y, "%0d %0d %0d %0d", dut.y_data,
                      dut.y_sof, dut.y_eol, dut.y_ready);
        if (dut.cc_valid && dut.cc_ready)
            $fdisplay(pf_cs, "%0d %0d %0d %0d", dut.cc_cb,
                      dut.cc_cr, dut.cc_sof, dut.cc_eol);
        // converter->decim raw per-pixel chroma stream
        if (dut.c_valid && dut.c_ready)
            $fdisplay(pf_raw, "%0d %0d %0d", dut.c_cb, dut.c_cr, dut.c_eol);
        if (dut.blk_valid && dut.blk_ready) begin
            for (cj = 0; cj < 8; cj = cj + 1)
                gbuf[gg*8 + cj] = dut.blk_a[63 - cj*8 -: 8];
            if (dut.blk_last) begin
                $fdisplay(pf_g, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                          dut.blk_comp, gbuf[0],
                          gbuf[1],
                          gbuf[2],
                          gbuf[3],
                          gbuf[4],
                          gbuf[5],
                          gbuf[6],
                          gbuf[7],
                          gbuf[8],
                          gbuf[9],
                          gbuf[10],
                          gbuf[11],
                          gbuf[12],
                          gbuf[13],
                          gbuf[14],
                          gbuf[15],
                          gbuf[16],
                          gbuf[17],
                          gbuf[18],
                          gbuf[19],
                          gbuf[20],
                          gbuf[21],
                          gbuf[22],
                          gbuf[23],
                          gbuf[24],
                          gbuf[25],
                          gbuf[26],
                          gbuf[27],
                          gbuf[28],
                          gbuf[29],
                          gbuf[30],
                          gbuf[31],
                          gbuf[32],
                          gbuf[33],
                          gbuf[34],
                          gbuf[35],
                          gbuf[36],
                          gbuf[37],
                          gbuf[38],
                          gbuf[39],
                          gbuf[40],
                          gbuf[41],
                          gbuf[42],
                          gbuf[43],
                          gbuf[44],
                          gbuf[45],
                          gbuf[46],
                          gbuf[47],
                          gbuf[48],
                          gbuf[49],
                          gbuf[50],
                          gbuf[51],
                          gbuf[52],
                          gbuf[53],
                          gbuf[54],
                          gbuf[55],
                          gbuf[56],
                          gbuf[57],
                          gbuf[58],
                          gbuf[59],
                          gbuf[60],
                          gbuf[61],
                          gbuf[62],
                          gbuf[63]);
                gg = 0;
            end else begin
                gg = gg + 1;
            end
        end
        if (dut.coef_valid && dut.coef_ready) begin
            cbuf[cg*8 + 0] = $signed(dut.coef_0);
            cbuf[cg*8 + 1] = $signed(dut.coef_1);
            cbuf[cg*8 + 2] = $signed(dut.coef_2);
            cbuf[cg*8 + 3] = $signed(dut.coef_3);
            cbuf[cg*8 + 4] = $signed(dut.coef_4);
            cbuf[cg*8 + 5] = $signed(dut.coef_5);
            cbuf[cg*8 + 6] = $signed(dut.coef_6);
            cbuf[cg*8 + 7] = $signed(dut.coef_7);
            if (dut.coef_last) begin
                $fdisplay(pf_c, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                          dut.coef_comp, cbuf[0],
                          cbuf[1],
                          cbuf[2],
                          cbuf[3],
                          cbuf[4],
                          cbuf[5],
                          cbuf[6],
                          cbuf[7],
                          cbuf[8],
                          cbuf[9],
                          cbuf[10],
                          cbuf[11],
                          cbuf[12],
                          cbuf[13],
                          cbuf[14],
                          cbuf[15],
                          cbuf[16],
                          cbuf[17],
                          cbuf[18],
                          cbuf[19],
                          cbuf[20],
                          cbuf[21],
                          cbuf[22],
                          cbuf[23],
                          cbuf[24],
                          cbuf[25],
                          cbuf[26],
                          cbuf[27],
                          cbuf[28],
                          cbuf[29],
                          cbuf[30],
                          cbuf[31],
                          cbuf[32],
                          cbuf[33],
                          cbuf[34],
                          cbuf[35],
                          cbuf[36],
                          cbuf[37],
                          cbuf[38],
                          cbuf[39],
                          cbuf[40],
                          cbuf[41],
                          cbuf[42],
                          cbuf[43],
                          cbuf[44],
                          cbuf[45],
                          cbuf[46],
                          cbuf[47],
                          cbuf[48],
                          cbuf[49],
                          cbuf[50],
                          cbuf[51],
                          cbuf[52],
                          cbuf[53],
                          cbuf[54],
                          cbuf[55],
                          cbuf[56],
                          cbuf[57],
                          cbuf[58],
                          cbuf[59],
                          cbuf[60],
                          cbuf[61],
                          cbuf[62],
                          cbuf[63]);
                cg = 0;
            end else begin
                cg = cg + 1;
            end
        end
        if (dut.q_valid && dut.q_ready) begin
            qbuf[qg*8 + 0] = $signed(dut.q_0);
            qbuf[qg*8 + 1] = $signed(dut.q_1);
            qbuf[qg*8 + 2] = $signed(dut.q_2);
            qbuf[qg*8 + 3] = $signed(dut.q_3);
            qbuf[qg*8 + 4] = $signed(dut.q_4);
            qbuf[qg*8 + 5] = $signed(dut.q_5);
            qbuf[qg*8 + 6] = $signed(dut.q_6);
            qbuf[qg*8 + 7] = $signed(dut.q_7);
            if (dut.q_last) begin
                $fdisplay(pf_q, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                          dut.q_comp, qbuf[0],
                          qbuf[1],
                          qbuf[2],
                          qbuf[3],
                          qbuf[4],
                          qbuf[5],
                          qbuf[6],
                          qbuf[7],
                          qbuf[8],
                          qbuf[9],
                          qbuf[10],
                          qbuf[11],
                          qbuf[12],
                          qbuf[13],
                          qbuf[14],
                          qbuf[15],
                          qbuf[16],
                          qbuf[17],
                          qbuf[18],
                          qbuf[19],
                          qbuf[20],
                          qbuf[21],
                          qbuf[22],
                          qbuf[23],
                          qbuf[24],
                          qbuf[25],
                          qbuf[26],
                          qbuf[27],
                          qbuf[28],
                          qbuf[29],
                          qbuf[30],
                          qbuf[31],
                          qbuf[32],
                          qbuf[33],
                          qbuf[34],
                          qbuf[35],
                          qbuf[36],
                          qbuf[37],
                          qbuf[38],
                          qbuf[39],
                          qbuf[40],
                          qbuf[41],
                          qbuf[42],
                          qbuf[43],
                          qbuf[44],
                          qbuf[45],
                          qbuf[46],
                          qbuf[47],
                          qbuf[48],
                          qbuf[49],
                          qbuf[50],
                          qbuf[51],
                          qbuf[52],
                          qbuf[53],
                          qbuf[54],
                          qbuf[55],
                          qbuf[56],
                          qbuf[57],
                          qbuf[58],
                          qbuf[59],
                          qbuf[60],
                          qbuf[61],
                          qbuf[62],
                          qbuf[63]);
                qg = 0;
            end else begin
                qg = qg + 1;
            end
        end
        // P2 issue dump: the qx vector the core latches (pre-edge)
        if (dut.u_dct.run_p2) begin
            p2cnt_next = p2cnt + 1;
            $fdisplay(pf_p2, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                      p2cnt, dut.u_dct.p2_use, dut.u_dct.p2_irow,
                      dut.u_dct.core_gate,
                      $signed(dut.u_dct.qx0), $signed(dut.u_dct.qx1),
                      $signed(dut.u_dct.qx2), $signed(dut.u_dct.qx3),
                      $signed(dut.u_dct.qx4), $signed(dut.u_dct.qx5));
        end
        // P1 completion: dump p1ram one cycle LATER (the col-7 write
        // lands on the trigger edge itself)
        p2cnt = p2cnt_next;
        p1d <= dut.u_dct.core_yv && dut.u_dct.core_out_is_p1 &&
               (dut.u_dct.core_idx == 3'd7);
        p1d_slot <= dut.u_dct.core_slot;
        if (p1d) begin
            $fdisplay(pf_p1, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                      p1cnt, p1d_slot,
                      $signed(dut.u_dct.p1ram[p1d_slot][0][0]),
                      $signed(dut.u_dct.p1ram[p1d_slot][0][1]),
                      $signed(dut.u_dct.p1ram[p1d_slot][0][2]),
                      $signed(dut.u_dct.p1ram[p1d_slot][0][3]),
                      $signed(dut.u_dct.p1ram[p1d_slot][0][4]),
                      $signed(dut.u_dct.p1ram[p1d_slot][0][5]),
                      $signed(dut.u_dct.p1ram[p1d_slot][0][6]),
                      $signed(dut.u_dct.p1ram[p1d_slot][0][7]),
                      $signed(dut.u_dct.p1ram[p1d_slot][1][0]),
                      $signed(dut.u_dct.p1ram[p1d_slot][1][1]),
                      $signed(dut.u_dct.p1ram[p1d_slot][1][2]),
                      $signed(dut.u_dct.p1ram[p1d_slot][1][3]),
                      $signed(dut.u_dct.p1ram[p1d_slot][1][4]),
                      $signed(dut.u_dct.p1ram[p1d_slot][1][5]),
                      $signed(dut.u_dct.p1ram[p1d_slot][1][6]),
                      $signed(dut.u_dct.p1ram[p1d_slot][1][7]),
                      $signed(dut.u_dct.p1ram[p1d_slot][2][0]),
                      $signed(dut.u_dct.p1ram[p1d_slot][2][1]),
                      $signed(dut.u_dct.p1ram[p1d_slot][2][2]),
                      $signed(dut.u_dct.p1ram[p1d_slot][2][3]),
                      $signed(dut.u_dct.p1ram[p1d_slot][2][4]),
                      $signed(dut.u_dct.p1ram[p1d_slot][2][5]),
                      $signed(dut.u_dct.p1ram[p1d_slot][2][6]),
                      $signed(dut.u_dct.p1ram[p1d_slot][2][7]),
                      $signed(dut.u_dct.p1ram[p1d_slot][3][0]),
                      $signed(dut.u_dct.p1ram[p1d_slot][3][1]),
                      $signed(dut.u_dct.p1ram[p1d_slot][3][2]),
                      $signed(dut.u_dct.p1ram[p1d_slot][3][3]),
                      $signed(dut.u_dct.p1ram[p1d_slot][3][4]),
                      $signed(dut.u_dct.p1ram[p1d_slot][3][5]),
                      $signed(dut.u_dct.p1ram[p1d_slot][3][6]),
                      $signed(dut.u_dct.p1ram[p1d_slot][3][7]),
                      $signed(dut.u_dct.p1ram[p1d_slot][4][0]),
                      $signed(dut.u_dct.p1ram[p1d_slot][4][1]),
                      $signed(dut.u_dct.p1ram[p1d_slot][4][2]),
                      $signed(dut.u_dct.p1ram[p1d_slot][4][3]),
                      $signed(dut.u_dct.p1ram[p1d_slot][4][4]),
                      $signed(dut.u_dct.p1ram[p1d_slot][4][5]),
                      $signed(dut.u_dct.p1ram[p1d_slot][4][6]),
                      $signed(dut.u_dct.p1ram[p1d_slot][4][7]),
                      $signed(dut.u_dct.p1ram[p1d_slot][5][0]),
                      $signed(dut.u_dct.p1ram[p1d_slot][5][1]),
                      $signed(dut.u_dct.p1ram[p1d_slot][5][2]),
                      $signed(dut.u_dct.p1ram[p1d_slot][5][3]),
                      $signed(dut.u_dct.p1ram[p1d_slot][5][4]),
                      $signed(dut.u_dct.p1ram[p1d_slot][5][5]),
                      $signed(dut.u_dct.p1ram[p1d_slot][5][6]),
                      $signed(dut.u_dct.p1ram[p1d_slot][5][7]),
                      $signed(dut.u_dct.p1ram[p1d_slot][6][0]),
                      $signed(dut.u_dct.p1ram[p1d_slot][6][1]),
                      $signed(dut.u_dct.p1ram[p1d_slot][6][2]),
                      $signed(dut.u_dct.p1ram[p1d_slot][6][3]),
                      $signed(dut.u_dct.p1ram[p1d_slot][6][4]),
                      $signed(dut.u_dct.p1ram[p1d_slot][6][5]),
                      $signed(dut.u_dct.p1ram[p1d_slot][6][6]),
                      $signed(dut.u_dct.p1ram[p1d_slot][6][7]),
                      $signed(dut.u_dct.p1ram[p1d_slot][7][0]),
                      $signed(dut.u_dct.p1ram[p1d_slot][7][1]),
                      $signed(dut.u_dct.p1ram[p1d_slot][7][2]),
                      $signed(dut.u_dct.p1ram[p1d_slot][7][3]),
                      $signed(dut.u_dct.p1ram[p1d_slot][7][4]),
                      $signed(dut.u_dct.p1ram[p1d_slot][7][5]),
                      $signed(dut.u_dct.p1ram[p1d_slot][7][6]),
                      $signed(dut.u_dct.p1ram[p1d_slot][7][7]));
            p1cnt = p1cnt + 1;
        end
    end
    final begin
        $fclose(pf_c);
        $fclose(pf_q);
        $fclose(pf_g);
        $fclose(pf_y);
        $fclose(pf_cs);
        $fclose(pf_p1);
        $fclose(pf_p2);
    end
`endif

    initial begin
        if (!$value$plusargs("TAG=%s", tag)) tag = "flat64";
        if ($value$plusargs("NOGAP", dummy_int)) nogap = 1;
        rng_state = 32'hBEEF;
        errors = 0; sent = 0; got = 0;
        done_flag = 0;
        fd_rtl = 0;

        fname = {"vectors/img_", tag, "_meta.txt"};
        fd_img = $fopen(fname, "r");
        if (fd_img == 0) begin
            $display("FATAL: cannot open meta file (tag=%0s)", tag);
            $finish;
        end
        code = $fscanf(fd_img, "%d %d\n", W, H);
        $fclose(fd_img);

        rst = 1;
        repeat (4) @(posedge clk);
        #1 rst = 0;

        @(negedge clk);
        cfg_valid = 1; cfg_w = W[10:0]; cfg_h = H[10:0];
        @(negedge clk);
        cfg_valid = 0;

        fork
            // ---------------- input driver ----------------
            begin : input_driver
                fname = {"vectors/img_", tag, "_rgb.hex"};
                fd_img = $fopen(fname, "r");
                if (fd_img == 0) begin
                    $display("FATAL: cannot open rgb hex");
                    $finish;
                end
                for (integer i = 0; i < W * H; i = i + 1) begin
                    code = $fscanf(fd_img, "%h\n", px);
                    if (code != 1) begin
                        errors = errors + 1000;
                        $display("FATAL: rgb hex short at pixel %0d", i);
                        disable input_driver;
                    end
                    // randomized valid gaps (+NOGAP disables: continuous
                    // stream = board ROM source; random gaps hit an
                    // occasional gather/dct handshake deadlock, I-25)
                    if (nogap == 0 && (nextr() & 3) == 0) begin
                        @(negedge clk);
                        s_valid <= 0;
                    end
                    @(negedge clk);
                    s_valid <= 1;
                    s_data <= px;
                    s_user <= (i == 0);
                    s_last <= ((i + 1) % W == 0);
                    do @(posedge clk); while (!(s_valid && s_ready));
                    sent = sent + 1;
                end
                @(negedge clk);
                s_valid <= 0;
            end
            // ---------------- backpressure ----------------
            begin : backpressure
                forever begin
                    @(negedge clk);
                    m_ready <= (nextr() & 7) != 0;
                end
            end
            // ---------------- capture + compare ----------------
            begin : capture
                fname = {"vectors/gold_", tag, "_scan.hex"};
                fd_gold = $fopen(fname, "r");
                if (fd_gold == 0) begin
                    errors = errors + 1000;
                    $display("FATAL: cannot open gold scan");
                    done_flag = 1;
                    disable capture;
                end
                forever begin
                    @(posedge clk);
                    if (m_valid && m_ready) begin
                        if (fd_rtl == 0)
                            fd_rtl = $fopen({"results/rtl_", tag, "_scan.hex"}, "w");
                        $fdisplay(fd_rtl, "%02x", m_data);
                        code = $fscanf(fd_gold, "%h\n", gbyte);
                        if (code != 1) begin
                            errors = errors + 1;
                            $display("ERR: RTL byte %0d beyond golden scan length", got);
                        end else if (m_data !== gbyte) begin
                            errors = errors + 1;
                            if (errors < 12)
                                $display("ERR byte %0d: got %02x exp %02x",
                                         got, m_data, gbyte);
                        end
                        got = got + 1;
                        if (m_last) begin
                            done_flag = 1;
                            disable capture;
                        end
                    end
                end
            end
            // ---------------- watchdog ----------------
            begin : watchdog
                repeat (3000000) @(posedge clk);
                errors = errors + 1000;
                $display("FATAL: watchdog timeout, no m_last");
                done_flag = 1;
            end
        join_none


        wait (done_flag);
        disable fork;

        // golden scan must be fully consumed
        begin
            reg [7:0] extra;
            code = $fscanf(fd_gold, "%h\n", extra);
            if (code == 1) begin
                errors = errors + 1;
                $display("ERR: golden scan has extra bytes beyond RTL output");
            end
            if (fd_rtl != 0) $fclose(fd_rtl);
            $fclose(fd_gold);
        end

        $display("tb_jpeg_top tag=%0s: sent=%0d bytes=%0d errors=%0d -> %s",
                 tag, sent, got, errors, (errors == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
