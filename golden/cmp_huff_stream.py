#!/usr/bin/env python3
"""Symbol-level diff between the golden huff stream and the RTL huff stream
(results/rtl_huff_<tag>.hex, dumped by tb_huff). Decodes both with the mini
entropy decoder, block by block (component order from gold_<tag>_q.txt),
and prints the first divergent block with the symbol events around it."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import jpeg_golden as G
from jpeg_decode_check import BitReader, build_decode_tbl, decode_sym

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_bytes(path):
    out = bytearray()
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(int(line, 16))
    return bytes(out)


def decode_block_events(br, inv_dc, inv_ac):
    """Decode one block into symbol events (not coefficient values)."""
    ev = []
    s = decode_sym(br, inv_dc)
    diff = 0
    if s:
        diff = br.get(s)
        if diff < (1 << (s - 1)):
            diff -= (1 << s) - 1
    ev.append(("DC", s, diff))
    while True:
        rs = decode_sym(br, inv_ac)
        if rs == 0:
            ev.append(("EOB",))
            break
        run, sz = rs >> 4, rs & 15
        if sz == 0:
            if run == 15:
                ev.append(("ZRL",))
                continue
            raise ValueError("bad AC symbol %02x" % rs)
        v = br.get(sz)
        if v < (1 << (sz - 1)):
            v -= (1 << sz) - 1
        ev.append(("AC", run, sz, v))
    return ev


def decode_stream(data, comps):
    br = BitReader(data)
    inv = {k: build_decode_tbl(v) for k, v in G.HUFF.items()}
    out = []
    try:
        for comp in comps:
            if comp == 0:
                ev = decode_block_events(br, inv[(0, 0)], inv[(1, 0)])
            else:
                ev = decode_block_events(br, inv[(0, 1)], inv[(1, 1)])
            out.append((comp, ev))
    except (IndexError, ValueError) as e:
        out.append(("ERR", str(e)))
    return out


def main(tag):
    gold = read_bytes(os.path.join(ROOT, "vectors", "gold_%s_huff.txt" % tag))
    rtl = read_bytes(os.path.join(ROOT, "results", "rtl_huff_%s.hex" % tag))
    comps = []
    with open(os.path.join(ROOT, "vectors", "gold_%s_q.txt" % tag)) as f:
        for line in f:
            t = line.split()
            if t:
                comps.append(int(t[0]))
    print("tag=%s golden=%d bytes  rtl=%d bytes" % (tag, len(gold), len(rtl)))
    gb = decode_stream(gold, comps)
    rb = decode_stream(rtl, comps)
    for i in range(max(len(gb), len(rb))):
        g = gb[i] if i < len(gb) else None
        r = rb[i] if i < len(rb) else None
        ge = g[1] if g and g != "ERR" else None
        re_ = r[1] if r and r != "ERR" else None
        if ge != re_:
            print("first divergence at block %d (comp gold=%s rtl=%s)" %
                  (i, g[0] if g else "?", r[0] if r else "?"))
            print("  golden:", ge)
            print("  rtl   :", re_)
            print("  next golden blocks:")
            for j in range(i, min(i + 3, len(gb))):
                print("    [%d]" % j, gb[j][1])
            print("  next rtl blocks:")
            for j in range(i, min(i + 3, len(rb))):
                print("    [%d]" % j, rb[j][1])
            return
    print("streams decode identically (%d blocks)" % len(gb))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "noise64")
