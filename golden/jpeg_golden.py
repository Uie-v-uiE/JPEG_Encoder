#!/usr/bin/env python3
"""k5p-jpeg-encoder golden model (single source of truth).

Fixed-point Baseline JPEG encoder, bit-exactly mirrors the RTL:
  RGB888 -> JFIF integer YCbCr -> 4:2:0 (2x2 box, >>2) -> level shift (-128)
  -> integer FDCT (libjpeg jfdctint.c algorithm, CONST_BITS=13, PASS1_BITS=2,
     results scaled x8; reference source vendored at golden/jfdctint_ref.c)
  -> zigzag -> quantize: truncate-toward-zero division via per-coefficient
     exact reciprocal multiply (M', S') verified exhaustively over |v|<=8191
  -> Huffman encode (Annex K tables extracted from a libjpeg-produced file:
     golden/annexk_tables.json) -> MSB-first bitstream with 0xFF stuffing.

All arithmetic is integer; every operation has a one-to-one RTL mapping.
"""
import json
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))

# natural-order index visited at each zigzag position (JPEG spec A.3.3,
# matches libjpeg jpeg_natural_order)
ZZ = [0, 1, 8, 16, 9, 2, 3, 10,
      17, 24, 32, 25, 18, 11, 4, 5,
      12, 19, 26, 33, 40, 48, 41, 34,
      27, 20, 13, 6, 7, 14, 21, 28,
      35, 42, 49, 56, 57, 50, 43, 36,
      29, 22, 15, 23, 30, 37, 44, 51,
      58, 59, 52, 45, 38, 31, 39, 46,
      53, 60, 61, 54, 47, 55, 62, 63]
assert sorted(ZZ) == list(range(64))

# Annex K natural-order quant tables (verified against the extracted DQT)
QL_NAT = [16, 11, 10, 16, 24, 40, 51, 61,
          12, 12, 14, 19, 26, 58, 60, 55,
          14, 13, 16, 24, 40, 57, 69, 56,
          14, 17, 22, 29, 51, 87, 80, 62,
          18, 22, 37, 56, 68, 109, 103, 77,
          24, 35, 55, 64, 81, 104, 113, 92,
          49, 64, 78, 87, 103, 121, 120, 101,
          72, 92, 95, 98, 112, 100, 103, 99]
QC_NAT = [17, 18, 24, 47, 99, 99, 99, 99,
          18, 21, 26, 66, 99, 99, 99, 99,
          24, 26, 56, 99, 99, 99, 99, 99,
          47, 66, 99, 99, 99, 99, 99, 99,
          99, 99, 99, 99, 99, 99, 99, 99,
          99, 99, 99, 99, 99, 99, 99, 99,
          99, 99, 99, 99, 99, 99, 99, 99,
          99, 99, 99, 99, 99, 99, 99, 99]
# zigzag-ordered (as used by the pipeline and as carried in DQT segments)
QL = [QL_NAT[i] for i in ZZ]
QC = [QC_NAT[i] for i in ZZ]


def _load_huff():
    with open(os.path.join(HERE, "annexk_tables.json")) as f:
        t = json.load(f)
    huff = {}
    for tc, th, bits, vals in t["dht"]:
        code = 0
        k = 0
        tbl = {}
        for ln in range(1, 17):
            for _ in range(bits[ln - 1]):
                tbl[vals[k]] = (code, ln)
                code += 1
                k += 1
            code <<= 1
        huff[(tc, th)] = tbl
    # sanity: K.3 luminance DC word for category 0 is '00'
    assert huff[(0, 0)][0] == (0b00, 2)
    assert huff[(1, 0)][0x00] == (0b1010, 4)  # K.5 EOB
    return huff


HUFF = _load_huff()


# ------------------------------------------------------- RGB -> YCbCr (int)
def rgb2y(r, g, b):
    return (77 * r + 150 * g + 29 * b + 128) >> 8


def rgb2cb(r, g, b):
    return 128 + ((-43 * r - 85 * g + 128 * b) >> 8)


def rgb2cr(r, g, b):
    return 128 + ((128 * r - 107 * g - 21 * b) >> 8)


# ------------------------------------------------------------ 4:2:0 decim
def decim420(a, b, c, d):
    """2x2 box average, truncating >>2 (matches RTL arithmetic shift)."""
    return (a + b + c + d) >> 2


# ------------------------------------------------------- FDCT (jfdctint)
CB = 13   # CONST_BITS
PB = 2    # PASS1_BITS

FIX_0_298631336 = 2446
FIX_0_390180644 = 3196
FIX_0_541196100 = 4433
FIX_0_765366865 = 6270
FIX_0_899976223 = 7373
FIX_1_175875602 = 9633
FIX_1_501321110 = 12299
FIX_1_847759065 = 15137
FIX_1_961570560 = 16069
FIX_2_053119869 = 16819
FIX_2_562915447 = 20995
FIX_3_072711026 = 25172


def _descale(x, n):
    """DESCALE: rounded arithmetic right shift (matches >>> in RTL)."""
    return (x + (1 << (n - 1))) >> n


def fdct1d(x, first_pass):
    """One 1-D FDCT over 8 samples (jfdctint body). first_pass=True scales
    outputs by 2**PASS1_BITS; second pass removes it (overall x8)."""
    tmp0 = x[0] + x[7]
    tmp7 = x[0] - x[7]
    tmp1 = x[1] + x[6]
    tmp6 = x[1] - x[6]
    tmp2 = x[2] + x[5]
    tmp5 = x[2] - x[5]
    tmp3 = x[3] + x[4]
    tmp4 = x[3] - x[4]

    tmp10 = tmp0 + tmp3
    tmp13 = tmp0 - tmp3
    tmp11 = tmp1 + tmp2
    tmp12 = tmp1 - tmp2

    out = [0] * 8
    n = CB - PB if first_pass else CB + PB
    if first_pass:
        out[0] = (tmp10 + tmp11) << PB
        out[4] = (tmp10 - tmp11) << PB
    else:
        out[0] = _descale(tmp10 + tmp11, PB)
        out[4] = _descale(tmp10 - tmp11, PB)
    z1 = (tmp12 + tmp13) * FIX_0_541196100
    out[2] = _descale(z1 + tmp13 * FIX_0_765366865, n)
    out[6] = _descale(z1 - tmp12 * FIX_1_847759065, n)

    z1 = tmp4 + tmp7
    z2 = tmp5 + tmp6
    z3 = tmp4 + tmp6
    z4 = tmp5 + tmp7
    z5 = (z3 + z4) * FIX_1_175875602

    m4 = tmp4 * FIX_0_298631336
    m5 = tmp5 * FIX_2_053119869
    m6 = tmp6 * FIX_3_072711026
    m7 = tmp7 * FIX_1_501321110
    z1m = z1 * -FIX_0_899976223
    z2m = z2 * -FIX_2_562915447
    z3m = z3 * -FIX_1_961570560
    z4m = z4 * -FIX_0_390180644

    z3m += z5
    z4m += z5

    out[7] = _descale(m4 + z1m + z3m, n)
    out[5] = _descale(m5 + z2m + z4m, n)
    out[3] = _descale(m6 + z2m + z3m, n)
    out[1] = _descale(m7 + z1m + z4m, n)
    return out


def fdct2d(block):
    """8x8 FDCT, input 8x8 ints (level-shifted), output natural order.
    Pass 1 runs along COLUMNS, pass 2 along rows -- exactly matching the
    RTL (mcu_gather feeds one block column per cycle, so the first 1-D pass
    naturally runs along columns). jfdctint's two passes round differently,
    so the axis order changes results by +-1 vs libjpeg's row-first order;
    both are valid FDCTs (validated against the float DCT in gen_vectors)."""
    cols = [[block[r][c] for r in range(8)] for c in range(8)]
    tmp = [fdct1d(col, True) for col in cols]      # tmp[c][r]
    out = [[0] * 8 for _ in range(8)]
    for r in range(8):
        res = fdct1d([tmp[c][r] for c in range(8)], False)
        for c in range(8):
            out[r][c] = res[c]
    return out


# ---------------------------------------------------------------- quantize
# FDCT output carries libjpeg's overall x8 scaling, so the standard
# quantized value is trunc(FDCT / (8Q)).  Since 8Q = 8 * Q with Q <= 255:
#   trunc(v / (8Q)) = sign(v) * (((|v| >> 3) * M') >> S')   exactly,
# with M' = ceil(2^S'/Q) chosen per coefficient so the multiply error
# (vmax-1)*e*Q stays below 2^S' (e = M'*Q - 2^S' < Q).  |v|>>3 <= 1016.
# round-half-away-from-zero (matches libjpeg): trunc((|v| + 4Q) / (8Q));
# nested-floor identity makes ((|v| + 4Q) >> 3) // Q exact, so the same
# per-coefficient reciprocal multiply applies with |t| <= VQ_MAX.
VQ_MAX = (8191 + 4 * 255) >> 3   # 1151


def build_recip(qtab, vmax=VQ_MAX):
    """For each Q find the smallest S' (and M') exact for |v>>3| <= vmax."""
    out = []
    for q in qtab:
        for sp in range(1, 40):
            m = -(- (1 << sp) // q)              # ceil(2^sp / q)
            e = m * q - (1 << sp)                # 0 <= e < q
            if (vmax - 1) * e * q < (1 << sp):   # exactness condition
                out.append((m, sp))
                break
        else:
            raise AssertionError("no exact reciprocal for Q=%d" % q)
    return out


RECIP_L = build_recip(QL)
RECIP_C = build_recip(QC)


def quant1(v, q, m, sp):
    """Round-half-away divide by 8Q: sign * (((|v| + 4Q) >> 3) * M) >> S'."""
    t = ((v if v >= 0 else -v) + (q << 2)) >> 3
    r = (t * m) >> sp
    return r if v >= 0 else -r


def quantize_block(dct_natural, is_luma):
    """8x8 natural-order FDCT output -> zigzag order -> quantized 64."""
    qtab = QL if is_luma else QC
    rec = RECIP_L if is_luma else RECIP_C
    zz = [dct_natural[ZZ[k] // 8][ZZ[k] % 8] for k in range(64)]
    qtab = QL if is_luma else QC
    return [quant1(zz[k], qtab[k], rec[k][0], rec[k][1]) for k in range(64)]


# ---------------------------------------------------------------- huffman
def _cat(v):
    a = abs(v)
    s = 0
    while a:
        s += 1
        a >>= 1
    return s


def _amp_bits(v, s):
    """Spec F.1.2.3.1: v>=0 -> v; v<0 -> v + (1<<s) - 1 (s-bit pattern)."""
    if v >= 0:
        return v
    return v + (1 << s) - 1


class BitWriter:
    def __init__(self):
        self.acc = 0
        self.n = 0
        self.out = bytearray()

    def put(self, code, nbits):
        assert nbits <= 16 and code < (1 << nbits), (code, nbits)
        for i in range(nbits - 1, -1, -1):
            self.acc = (self.acc << 1) | ((code >> i) & 1)
            self.n += 1
            if self.n == 8:
                b = self.acc & 0xFF
                self.out.append(b)
                if b == 0xFF:
                    self.out.append(0x00)
                self.acc = 0
                self.n = 0

    def flush(self):
        while self.n:
            self.put(1, 1)   # pad with 1s to byte boundary
        return bytes(self.out)


def encode_block_huff(bw, qvals, dc_pred, tbl_dc, tbl_ac):
    """Encode one quantized block into the frame-level BitWriter (JPEG
    entropy data is NOT byte-aligned between blocks; only the final scan
    flush pads). Returns new DC predictor."""
    diff = qvals[0] - dc_pred
    s = _cat(diff)
    code, ln = tbl_dc[s]
    bw.put(code, ln)
    if s:
        bw.put(_amp_bits(diff, s), s)
    dc_new = qvals[0]

    run = 0
    for k in range(1, 64):
        v = qvals[k]
        if v == 0:
            run += 1
            continue
        while run >= 16:
            code, ln = tbl_ac[0xF0]
            bw.put(code, ln)
            run -= 16
        s = _cat(v)
        code, ln = tbl_ac[(run << 4) | s]
        bw.put(code, ln)
        bw.put(_amp_bits(v, s), s)
        run = 0
    if run:
        code, ln = tbl_ac[0x00]
        bw.put(code, ln)
    return dc_new


# ------------------------------------------------------------ frame encode
def encode_frame(rgb, w, h):
    """rgb: list of h rows of w (r,g,b); w,h multiples of 16.
    Returns the entropy-coded scan bytes (headers NOT included)."""
    assert w % 16 == 0 and h % 16 == 0
    yplane = [[rgb2y(*rgb[y][x]) for x in range(w)] for y in range(h)]
    cplane = [[None] * (w // 2) for _ in range(h // 2)]
    for y in range(h // 2):
        for x in range(w // 2):
            ys, xs = 2 * y, 2 * x
            r0, g0, b0 = rgb[ys][xs]
            r1, g1, b1 = rgb[ys][xs + 1]
            r2, g2, b2 = rgb[ys + 1][xs]
            r3, g3, b3 = rgb[ys + 1][xs + 1]
            cplane[y][x] = (
                decim420(rgb2cb(r0, g0, b0), rgb2cb(r1, g1, b1),
                         rgb2cb(r2, g2, b2), rgb2cb(r3, g3, b3)),
                decim420(rgb2cr(r0, g0, b0), rgb2cr(r1, g1, b1),
                         rgb2cr(r2, g2, b2), rgb2cr(r3, g3, b3)))

    pred = {"y": 0, "cb": 0, "cr": 0}
    bw = BitWriter()
    for my in range(h // 16):
        for mx in range(w // 16):
            for by in range(2):
                for bx in range(2):
                    blk = [[yplane[my * 16 + by * 8 + r][mx * 16 + bx * 8 + c] - 128
                            for c in range(8)] for r in range(8)]
                    q = quantize_block(fdct2d(blk), True)
                    pred["y"] = encode_block_huff(
                        bw, q, pred["y"], HUFF[(0, 0)], HUFF[(1, 0)])
            for comp, key in ((0, "cb"), (1, "cr")):
                blk = [[cplane[my * 8 + r][mx * 8 + c][comp] - 128
                        for c in range(8)] for r in range(8)]
                q = quantize_block(fdct2d(blk), False)
                pred[key] = encode_block_huff(
                    bw, q, pred[key], HUFF[(0, 1)], HUFF[(1, 1)])
    return bw.flush()


# ------------------------------------------------------------- JFIF wrap
def jfif_wrap(scan, w, h):
    """Wrap the entropy scan into a complete JFIF file (for PIL decode
    verification and as a deliverable container)."""
    out = bytearray()
    out += b"\xff\xd8"                                        # SOI
    out += b"\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    for tq, nat in ((0, QL_NAT), (1, QC_NAT)):
        seg = bytearray([tq]) + bytes(nat[ZZ[k]] for k in range(64))
        out += b"\xff\xdb" + struct.pack(">H", len(seg) + 2) + bytes(seg)
    out += b"\xff\xc0\x00\x11\x08" + struct.pack(">HH", h, w) + b"\x03"
    # 4:2:0 interleaved scan: Y sampling 2x2, Cb/Cr 1x1
    out += b"\x01\x22\x00\x02\x11\x01\x03\x11\x01"             # SOF0 4:2:0
    with open(os.path.join(HERE, "annexk_tables.json")) as f:
        dht = json.load(f)["dht"]
    for tc, th, bits, vals in dht:
        seg = bytearray([(tc << 4) | th]) + bytes(bits) + bytes(vals)
        out += b"\xff\xc4" + struct.pack(">H", len(seg) + 2) + bytes(seg)
    out += b"\xff\xda\x00\x0c\x03\x01\x00\x02\x11\x03\x11\x00\x3f\x00"  # SOS
    out += scan
    out += b"\xff\xd9"
    return bytes(out)
