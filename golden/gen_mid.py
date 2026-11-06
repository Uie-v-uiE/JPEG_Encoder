#!/usr/bin/env python3
"""Generate intermediate golden truths for unit TBs (run from project root):
  img_<tag>_y.hex        -- golden Y plane (raster)
  img_<tag>_c.hex        -- golden chroma plane (cb,cr per pixel)
  gold_<tag>_blk.txt     -- per block: comp + 64 natural-order FDCT coefficients
  gold_<tag>_q.txt       -- per block: comp + 64 quantized (zigzag) values
Image generators duplicate gen_vectors.gen_image exactly (same seeds).
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import jpeg_golden as G

VEC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "vectors")
os.makedirs(VEC, exist_ok=True)


def make_image(kind, w, h, seed):
    rng = random.Random(seed)
    img = []
    for y in range(h):
        row = []
        for x in range(w):
            if kind == "gradient":
                px = ((x * 255) // (w - 1), (y * 255) // (h - 1),
                      ((x + y) * 255) // (w + h - 2))
            elif kind == "noise":
                px = (rng.randrange(256), rng.randrange(256), rng.randrange(256))
            elif kind == "flat":
                px = (80, 160, 200)
            else:
                c = ((x >> 3) ^ (y >> 3)) & 1
                px = (c * 220 + 20, 255 - c * 180, (x * 3 + y) % 256)
            row.append(px)
        img.append(row)
    return img


def gen_mid(tag, w, h, kind, seed):
    img = make_image(kind, w, h, seed)
    yplane = [[G.rgb2y(*img[y][x]) for x in range(w)] for y in range(h)]
    cplane = [[(G.decim420(G.rgb2cb(*img[2*y][2*x]), G.rgb2cb(*img[2*y][2*x+1]),
                               G.rgb2cb(*img[2*y+1][2*x]), G.rgb2cb(*img[2*y+1][2*x+1])),
                G.decim420(G.rgb2cr(*img[2*y][2*x]), G.rgb2cr(*img[2*y][2*x+1]),
                               G.rgb2cr(*img[2*y+1][2*x]), G.rgb2cr(*img[2*y+1][2*x+1])))
               for x in range(w // 2)] for y in range(h // 2)]
    with open(os.path.join(VEC, "img_%s_y.hex" % tag), "w") as f:
        for y in range(h):
            for x in range(w):
                f.write("%02x\n" % yplane[y][x])
    with open(os.path.join(VEC, "img_%s_c.hex" % tag), "w") as f:
        for y in range(h // 2):
            for x in range(w // 2):
                f.write("%02x%02x\n" % (cplane[y][x][0], cplane[y][x][1]))
    blocks = []
    for my in range(h // 16):
        for mx in range(w // 16):
            for by in range(2):
                for bx in range(2):
                    blk = [[yplane[my*16+by*8+r][mx*16+bx*8+c] - 128
                            for c in range(8)] for r in range(8)]
                    blocks.append((0, G.fdct2d(blk)))
            for comp in (1, 2):
                blk = [[cplane[my*8+r][mx*8+c][comp-1] - 128
                        for c in range(8)] for r in range(8)]
                blocks.append((comp, G.fdct2d(blk)))
    # raw pixel blocks (gather unit TB golden): comp + 64 pixels [r][c]
    with open(os.path.join(VEC, "gold_%s_pix.txt" % tag), "w") as f:
        for my in range(h // 16):
            for mx in range(w // 16):
                for by in range(2):
                    for bx in range(2):
                        f.write("0 ")
                        for r in range(8):
                            for c in range(8):
                                f.write("%d " % yplane[my*16+by*8+r][mx*16+bx*8+c])
                        f.write("\n")
                for comp in (1, 2):
                    f.write("%d " % comp)
                    for r in range(8):
                        for c in range(8):
                            f.write("%d " % cplane[my*8+r][mx*8+c][comp-1])
                    f.write("\n")
    with open(os.path.join(VEC, "gold_%s_blk.txt" % tag), "w") as f:
        for comp, coef in blocks:
            f.write("%d " % comp)
            for r in range(8):
                for c in range(8):
                    f.write("%d " % coef[r][c])
            f.write("\n")
    with open(os.path.join(VEC, "gold_%s_q.txt" % tag), "w") as f:
        for comp, coef in blocks:
            q = G.quantize_block(coef, comp == 0)
            f.write("%d " % comp)
            for v in q:
                f.write("%d " % v)
            f.write("\n")
    print(tag, len(blocks), "blocks")


def main():
    gen_mid("flat64", 64, 64, "flat", 1)
    gen_mid("grad64", 64, 64, "gradient", 2)
    gen_mid("noise64", 64, 64, "noise", 3)
    gen_mid("pat128x96", 128, 96, "pattern", 4)


if __name__ == "__main__":
    main()
