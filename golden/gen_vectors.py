#!/usr/bin/env python3
"""Generate verification vectors for k5p-jpeg-encoder (run from project root).
Outputs:
  vectors/img_<tag>_rgb.hex    -- input RGB raster (6 hex digits per pixel)
  vectors/img_<tag>_w_h.txt    -- dimensions
  vectors/gold_<tag>_scan.hex  -- golden entropy scan, 2 hex digits per byte
Also runs a column-first FDCT self-check (RTL computes columns first).
"""
import os
import sys
import random

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import jpeg_golden as G

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VEC = os.path.join(ROOT, "vectors")
os.makedirs(VEC, exist_ok=True)


import math


def float_dct2(blk):
    """Reference float DCT (orthonormal), scaled x8 like the fixed-point."""
    out = [[0.0] * 8 for _ in range(8)]
    for u in range(8):
        for v in range(8):
            # JPEG FDCT: F(u,v) = (1/4) C_u C_v * sum, C = 1/sqrt(2) at 0
            # x8 jfdctint scale: 8*(1/4)*C_u = 2*C_u with C_u=1/sqrt(2)@0;
            # the code multiplies by 8, so su*sv must equal C_u*C_v/4
            su = 0.5 / math.sqrt(2.0) if u == 0 else 0.5
            sv = 0.5 / math.sqrt(2.0) if v == 0 else 0.5
            s = 0.0
            for x in range(8):
                for y in range(8):
                    s += (blk[x][y] *
                          math.cos((2 * x + 1) * u * math.pi / 16) *
                          math.cos((2 * y + 1) * v * math.pi / 16))
            out[u][v] = 8 * su * sv * s
    return out


def selfcheck_fdct():
    """Golden fdct2d (column-first, matching RTL) must stay within 2 LSB of
    the float reference (jfdctint guarantees tight rounding)."""
    rng = random.Random(20261105)
    worst = 0
    for i in range(200):
        blk = [[rng.randrange(-128, 128) for _ in range(8)] for _ in range(8)]
        a = G.fdct2d(blk)
        b = float_dct2(blk)
        for r in range(8):
            for c in range(8):
                d = abs(a[r][c] - b[r][c])
                worst = max(worst, d)
                assert d <= 2.0, ("fdct vs float out of bound", i, r, c, a[r][c], b[r][c])
    print("fdct vs float DCT: worst |err| =", worst)


def gen_image(tag, w, h, kind, seed):
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
            else:  # pattern
                c = ((x >> 3) ^ (y >> 3)) & 1
                px = (c * 220 + 20, 255 - c * 180, (x * 3 + y) % 256)
            row.append(px)
        img.append(row)
    scan = G.encode_frame(img, w, h)
    with open(os.path.join(VEC, "img_%s_rgb.hex" % tag), "w") as f:
        for y in range(h):
            for x in range(w):
                r, g, b = img[y][x]
                f.write("%02x%02x%02x\n" % (r, g, b))
    with open(os.path.join(VEC, "img_%s_meta.txt" % tag), "w") as f:
        f.write("%d %d\n" % (w, h))
    with open(os.path.join(VEC, "gold_%s_scan.hex" % tag), "w") as f:
        for byte in scan:
            f.write("%02x\n" % byte)
    # also emit the JFIF for reference decoding
    open(os.path.join(VEC, "gold_%s.jpg" % tag), "wb").write(G.jfif_wrap(scan, w, h))
    print(tag, "%dx%d" % (w, h), "scan", len(scan), "bytes")


def main():
    selfcheck_fdct()
    gen_image("flat64", 64, 64, "flat", 1)
    gen_image("grad64", 64, 64, "gradient", 2)
    gen_image("noise64", 64, 64, "noise", 3)
    gen_image("pat128x96", 128, 96, "pattern", 4)
    print("vectors done")


if __name__ == "__main__":
    main()
