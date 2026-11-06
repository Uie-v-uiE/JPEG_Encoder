#!/usr/bin/env python3
"""Mini baseline-Huffman entropy decoder -- self-check utility.
Decodes a golden scan back into quantized coefficient blocks so the encoder
can be validated stage by stage (not a deliverable decoder)."""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import jpeg_golden as G


class BitReader:
    def __init__(self, data):
        # remove byte-stuffing: every raw 0xFF in entropy data is stored as
        # FF 00 -- strip the 00 before bit-level reading
        self.data = data.replace(b'\xff\x00', b'\xff')
        self.pos = 0   # bit position

    def get(self, n):
        v = 0
        for _ in range(n):
            byte = self.data[self.pos >> 3]
            bit = (byte >> (7 - (self.pos & 7))) & 1
            v = (v << 1) | bit
            self.pos += 1
        return v

    def peek_nonstuffed(self):
        return False


def build_decode_tbl(tbl):
    """code->(len,symbol) map for canonical table."""
    inv = {}
    for sym, (code, ln) in tbl.items():
        inv[(ln, code)] = sym
    return inv


def decode_sym(br, inv):
    code = 0
    for ln in range(1, 17):
        code = (code << 1) | br.get(1)
        if (ln, code) in inv:
            return inv[(ln, code)]
    raise ValueError("bad huffman code")


def decode_block(br, inv_dc, inv_ac, pred):
    q = [0] * 64
    s = decode_sym(br, inv_dc)
    diff = 0
    if s:
        diff = br.get(s)
        if diff < (1 << (s - 1)):
            diff -= (1 << s) - 1
    q[0] = pred + diff
    k = 1
    while k < 64:
        rs = decode_sym(br, inv_ac)
        if rs == 0:
            break
        run, sz = rs >> 4, rs & 15
        if sz == 0:
            if run == 15:
                k += 16
                continue
            raise ValueError("bad AC symbol %02x" % rs)
        k += run
        v = br.get(sz)
        if v < (1 << (sz - 1)):
            v -= (1 << sz) - 1
        q[k] = v
        k += 1
    return q, q[0]


def decode_scan(scan, w, h):
    br = BitReader(scan)
    inv = {k: build_decode_tbl(v) for k, v in G.HUFF.items()}
    pred = {"y": 0, "cb": 0, "cr": 0}
    blocks = []
    for my in range(h // 16):
        for mx in range(w // 16):
            for comp, key, tdc, tac in (
                    ("y", "y", (0, 0), (1, 0)),
                    ("y", "y", (0, 0), (1, 0)),
                    ("y", "y", (0, 0), (1, 0)),
                    ("y", "y", (0, 0), (1, 0)),
                    ("cb", "cb", (0, 1), (1, 1)),
                    ("cr", "cr", (0, 1), (1, 1))):
                q, pred[key] = decode_block(br, inv[tdc], inv[tac], pred[key])
                blocks.append((comp, q))
    return blocks
