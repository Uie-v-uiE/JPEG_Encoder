"""Rewrite the tb_jpeg_top PROBE section as an always @(posedge) monitor with
pre-edge read semantics (matches what quant latches). One-shot tool script."""
import io

P = r"D:\Xilinx\Harness\Project\new_prj\k5p-jpeg-encoder\tb\tb_jpeg_top.sv"
s = io.open(P, encoding="utf-8", errors="replace").read()
start = s.index("`ifdef PROBE")
end = s.index("`endif", start) + len("`endif")

FMT_C = " ".join(["%0d"] * 65)
FMT_Q = " ".join(["%0d"] * 65)
FMT_G = " ".join(["%0d"] * 65)
FMT_P1 = " ".join(["%0d"] * 66)


def spread(prefix, arr, n):
    return ",\n                              ".join(
        "%s[%d]" % (arr, i) for i in range(n))


def p1ram(slot):
    return ",\n                          ".join(
        "$signed(dut.u_dct.p1ram[p1d_slot][%d][%d])" % (c, u)
        for c in range(8) for u in range(8))


new_probe = """`ifdef PROBE
        // debug taps, all sampled inside always @(posedge) so every read
        // sees the SAME pre-edge values the consumer latches (negedge or
        // post-edge reads race the register update on back-to-back streams)
        reg p1d;
        reg [1:0] p1d_slot;
        integer pf_c, pf_q, pf_g, pf_y, pf_cs, pf_p1;
        reg signed [15:0] cbuf [0:63];
        reg signed [15:0] qbuf [0:63];
        reg [7:0] gbuf [0:63];
        integer cg, qg, gg, cj, p1cnt;
        initial begin
            cg = 0; qg = 0; gg = 0; p1cnt = 0; p1d = 0; p1d_slot = 0;
            pf_c = $fopen({"results/probe_", tag, "_blk.txt"}, "w");
            pf_q = $fopen({"results/probe_", tag, "_q.txt"}, "w");
            pf_g = $fopen({"results/probe_", tag, "_in.txt"}, "w");
            pf_y = $fopen({"results/probe_", tag, "_ystr.txt"}, "w");
            pf_cs = $fopen({"results/probe_", tag, "_cstr.txt"}, "w");
            pf_p1 = $fopen({"results/probe_", tag, "_p1.txt"}, "w");
        end
        always @(posedge clk) if (!done_flag) begin
            if (dut.y_valid && dut.y_ready)
                $fdisplay(pf_y, "%0d %0d %0d %0d", dut.y_data,
                          dut.y_sof, dut.y_eol, dut.y_ready);
            if (dut.cc_valid && dut.cc_ready)
                $fdisplay(pf_cs, "%0d %0d %0d %0d", dut.cc_cb,
                          dut.cc_cr, dut.cc_sof, dut.cc_eol);
            if (dut.blk_valid && dut.blk_ready) begin
                for (cj = 0; cj < 8; cj = cj + 1)
                    gbuf[gg*8 + cj] = dut.blk_a[63 - cj*8 -: 8];
                if (dut.blk_last) begin
                    $fdisplay(pf_g, "__FMT_G__",
                              dut.blk_comp, __SPREAD_G__);
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
                    $fdisplay(pf_c, "__FMT_C__",
                              dut.coef_comp, __SPREAD_C__);
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
                    $fdisplay(pf_q, "__FMT_Q__",
                              dut.q_comp, __SPREAD_Q__);
                    qg = 0;
                end else begin
                    qg = qg + 1;
                end
            end
            // P1 completion: dump p1ram one cycle LATER (the col-7 write
            // lands on the trigger edge itself)
            p1d <= dut.u_dct.core_yv && dut.u_dct.core_out_is_p1 &&
                   (dut.u_dct.core_idx == 3'd7);
            p1d_slot <= dut.u_dct.core_slot;
            if (p1d) begin
                $fdisplay(pf_p1, "__FMT_P1__",
                          p1cnt, p1d_slot,
                          __P1RAM__);
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
        end
`endif"""

new_probe = new_probe.replace("__FMT_G__", FMT_G).replace(
    "__SPREAD_G__", spread("gbuf", "gbuf", 64))
new_probe = new_probe.replace("__FMT_C__", FMT_C).replace(
    "__SPREAD_C__", spread("cbuf", "cbuf", 64))
new_probe = new_probe.replace("__FMT_Q__", FMT_Q).replace(
    "__SPREAD_Q__", spread("qbuf", "qbuf", 64))
new_probe = new_probe.replace("__FMT_P1__", FMT_P1).replace(
    "__P1RAM__", p1ram("p1d_slot"))

s = s[:start] + new_probe + s[end:]
io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("probe rewritten, %d bytes" % len(s))
