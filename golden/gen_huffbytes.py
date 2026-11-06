#!/usr/bin/env python3
"""Generate per-block Huffman byte goldens for the huff_enc unit TB:
  gold_<tag>_huff.txt  -- per line: comp, nbytes, then the entropy bytes
(duplicate of encode_frame's per-block encoding, sequential DC predictors)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import jpeg_golden as G
import gen_mid

VEC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "vectors")


def gen_huff(tag, w, h, kind, seed):
    img = gen_mid.make_image(kind, w, h, seed)
    yplane = [[G.rgb2y(*img[y][x]) for x in range(w)] for y in range(h)]
    cplane = [[(G.decim420(G.rgb2cb(*img[2*y][2*x]), G.rgb2cb(*img[2*y][2*x+1]),
                               G.rgb2cb(*img[2*y+1][2*x]), G.rgb2cb(*img[2*y+1][2*x+1])),
                G.decim420(G.rgb2cr(*img[2*y][2*x]), G.rgb2cr(*img[2*y][2*x+1]),
                               G.rgb2cr(*img[2*y+1][2*x]), G.rgb2cr(*img[2*y+1][2*x+1])))
               for x in range(w // 2)] for y in range(h // 2)]
    bw = G.BitWriter()
    pred = {"y": 0, "cb": 0, "cr": 0}
    out_lines = []
    out_start = 0
    for my in range(h // 16):
        for mx in range(w // 16):
            for by in range(2):
                for bx in range(2):
                    blk = [[yplane[my*16+by*8+r][mx*16+bx*8+c] - 128
                            for c in range(8)] for r in range(8)]
                    q = G.quantize_block(G.fdct2d(blk), True)
                    pred["y"] = G.encode_block_huff(bw, q, pred["y"],
                                                    G.HUFF[(0, 0)], G.HUFF[(1, 0)])
                    out_lines.append(("0", list(bw.out[out_start:])))
                    out_start = len(bw.out)
            for comp, key in ((1, "cb"), (2, "cr")):
                blk = [[cplane[my*8+r][mx*8+c][comp-1] - 128
                        for c in range(8)] for r in range(8)]
                q = G.quantize_block(G.fdct2d(blk), False)
                pred[key] = G.encode_block_huff(bw, q, pred[key],
                                                G.HUFF[(0, 1)], G.HUFF[(1, 1)])
                out_lines.append((str(comp), list(bw.out[out_start:])))
                out_start = len(bw.out)
    with open(os.path.join(VEC, "gold_%s_huff.txt" % tag), "w") as f:
        for comp, data in out_lines:
            for b in data:
                f.write('%02x\n' % b)
    print(tag, len(out_lines), "blocks")


def main():
    gen_huff("flat64", 64, 64, "flat", 1)
    gen_huff("noise64", 64, 64, "noise", 3)
    gen_huff("grad64", 64, 64, "gradient", 2)
    gen_huff("pat128x96", 128, 96, "pattern", 4)


if __name__ == "__main__":
    main()
