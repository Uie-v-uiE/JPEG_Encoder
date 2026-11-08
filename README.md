# FPGA JPEG Encoder

Baseline JPEG compression pipeline for Kintex UltraScale+ (RK-XCKU5P-F), verified bit-exact against a Python golden model.

[![Verification](https://img.shields.io/badge/verification-4%2F4%20images%20byte--exact-brightgreen)]() [![Timing](https://img.shields.io/badge/timing-100MHz%20closed-blue)]() [![Zero IP](https://img.shields.io/badge/vendor_IP-zero%20instances-blue)]()

## What this does

A complete Baseline JPEG encoding pipeline:
```
RGB888 → RGB→YCbCr → 4:2:0 chroma decimation → 8×8 block gather
      → 2D DCT (row/col 1D pipeline) → Quantization → Zigzag → Huffman
      → Entropy-coded byte stream (with JPEG headers)
```

Zero vendor IP instances. All DSP48E2, BRAM, and logic inferred from RTL.

## Verification

- **Golden model** (`golden/jpeg_golden.py`): quantization tables exhaustively verified over 2M+ cases, DCT vs floating-point ≤1.18 LSB, PSNR matches libjpeg q50 exactly
- **End-to-end**: 4 test images (flat64, grad64, noise64, pat128x96) encoded on FPGA, output byte stream compared byte-exact against golden model — 4/4 PASS
- **Unit tests**: DCT 2000 vectors, gather 4 images, huffman 4 images, decimation 4 images

## Project structure

```
rtl/
  jpeg_top.v         — Pipeline top level (AXI-Stream RGB in, byte stream out)
  rgb2ycbcr.v        — RGB→YCbCr color space conversion (DSP-based)
  decim420.v         — 4:2:0 chroma decimation (2× horizontal, 2× vertical)
  mcu_gather.v       — 8×8 block assembly with double-buffered row store
  dct2d.v            — 2D DCT via two 1D passes (8-parallel row, then column)
  fdct1d_llm.v       — 1D forward DCT (Loeffler-Ligtenberg-Moshenberg)
  quant.v            — Coefficient quantization (M'/S' pair per coefficient)
  huff_enc.v         — Huffman entropy encoder (DC + AC tables)
golden/
  jpeg_golden.py     — Bit-exact Python golden model
  gen_vectors.py     — Test image and intermediate file generator
  gen_mid.py         — Intermediate pipeline file generator
  jchuff_ref.c       — libjpeg reference (for table comparison)
vectors/
  img_*_rgb.hex      — Test image inputs (RGB888)
  gold_*_scan.hex    — Golden entropy-coded output streams
constr/
  jpeg_demo_board.xdc — KU5P pin constraints
scripts/
  synth_ooc.tcl      — OOC synthesis (100 MHz)
  build_board.tcl    — Board bitstream build
docs/
  DESIGN.md          — Pipeline architecture
  LOG.md             — Debugging chronology
  ISSUES.md          — Issue tracking (I-20 through I-25)
```

## Reproduce

```bash
# ModelSim simulation
cd sim
vsim -c -do do run_jpeg.do

# Vivado synthesis
vivado -mode batch -source scripts/synth_ooc.tcl

# Board bitstream (KU5P)
vivado -mode batch -source scripts/build_board.tcl
```

## Board demo

Burn `jpeg_demo_board.bit` via JTAG. The board encodes a built-in 64×64 test image and sends the JPEG byte stream via UART (115200-8N1). Compare with `vectors/gold_flat64_scan.hex`.

## Known issues

- **I-25**: Occasional deadlock under random input valid gaps (gather/dct handshake race). Continuous input (board ROM source) does not trigger.
- **I-22**: OOC synthesis of per-row RAM model exceeds synthesis tool memory. Requires RAM restructuring for synthesis.
