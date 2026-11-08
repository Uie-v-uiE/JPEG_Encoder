# LEARNING — JPEG Encoder: Pipeline Architecture & Knowledge Guide

This document explains the JPEG compression algorithm, the hardware pipeline design, and the engineering lessons from implementing it in RTL.

---

## 1. JPEG Compression Algorithm

### 1.1 Pipeline overview

```
Input (RGB888) → Color Convert (YCbCr) → Chroma Subsample (4:2:0)
→ Block Split (8×8) → Forward DCT → Quantization → Zigzag Scan
→ DC/AC Differential Coding → Huffman Entropy Coding → Output (JFIF bytes)
```

### 1.2 Color space conversion

RGB→YCbCr is a linear transform:
```
Y  =  0.299·R + 0.587·G + 0.114·B
Cb = −0.169·R − 0.331·G + 0.500·B + 128
Cr =  0.500·R − 0.419·G − 0.081·B + 128
```

In fixed-point hardware, the coefficients are scaled by 2^14 and the multiply uses DSP48E2 blocks. The +128 offset keeps Cb/Cr in unsigned range.

### 1.3 4:2:0 Chroma subsampling

The human eye is less sensitive to color than brightness. 4:2:0 means:
- Y (luminance): full resolution
- Cb, Cr (chrominance): half resolution in both horizontal and vertical

Each 2×2 pixel block produces:
- 4 Y samples (one per pixel)
- 1 Cb sample (average of 4)
- 1 Cr sample (average of 4)

In hardware, this requires a line buffer (store odd rows, average with even rows) and a 2:1 horizontal decimation.

### 1.4 8×8 Block DCT

Each 8×8 block of Y, Cb, or Cr undergoes a 2D Discrete Cosine Transform:

```
F(u,v) = (1/4)·C(u)·C(v) · Σ(x=0..7) Σ(y=0..7) f(x,y) · cos((2x+1)uπ/16) · cos((2y+1)vπ/16)
```

The 2D DCT is separable: apply 1D DCT to rows first, then to columns. Each 1D DCT uses the Loeffler-Ligtenberg-Moshenberg (LLM) algorithm, which requires only 11 multiplies and 29 adds (vs. 64 for direct computation).

**Hardware pipeline**: Two stages of 8-parallel 1D DCTs with a transposition buffer in between.

### 1.5 Quantization

Each DCT coefficient is divided by a quality-dependent quantization value:
```
Q(u,v) = round(F(u,v) / Q_table(u,v))
```

The quantization table is stored in ROM. For hardware, division is replaced by multiplication by the reciprocal (M = 2^k / Q) and a shift (S = log2(2^k/Q)). Each coefficient has a precomputed (M', S') pair stored in ROM.

### 1.6 Zigzag scan

After quantization, most high-frequency coefficients are zero. The zigzag scan reorders the 8×8 matrix into a 64-element vector, grouping low-frequency (non-zero) coefficients first and high-frequency (zero) coefficients last. This enables efficient run-length coding.

### 1.7 Entropy coding

JPEG uses Huffman coding:
- **DC coefficient**: Differential coding (difference from previous block's DC), then category + amplitude bits
- **AC coefficients**: Run-length encoding (run of zeros, then value), then category + amplitude bits

The Huffman tables are stored in ROM. The encoder outputs a bit-serial stream that is packed into bytes. Extra 1-bits are padded at the end. A 0xFF byte in the data is followed by 0x00 (byte stuffing) to avoid confusion with the 0xFFD9 end-of-image marker.

---

## 2. Hardware Pipeline Design

### 2.1 Module structure

```
jpeg_top
├── rgb2ycbcr.v     — 1 px/clock, DSP multiply, 2-cycle latency
├── decim420.v      — Line buffer + decimation, ~W cycles/row
├── mcu_gather.v    — Double-buffered 8×8 block assembly
├── dct2d.v         — Two-pass 1D DCT (row then column), 2×8 cycles/block
│   └── fdct1d_llm.v — 8-parallel 1D DCT butterfly
├── quant.v         — 8-parallel quantization, 2-deep coefficient slots
└── huff_enc.v      — Huffman engine, bit-packer, 2-deep block slots
```

All modules use valid/ready handshaking (AXI-Stream style) for flow control.

### 2.2 Double buffering

Each pipeline stage uses double-buffered slots to decouple producer and consumer rates:
- While the producer fills slot A, the consumer drains slot B
- When both complete, roles swap

This is implemented in `mcu_gather` (row buffer), `dct2d` (slot state machine), `quant` (coefficient slots), and `huff_enc` (block slots).

### 2.3 Handshake protocol

Each stage uses valid/ready:
- **valid**: "I have data for you"
- **ready**: "I can accept data"
- Transfer occurs when both are high (same clock edge)

The `ready` signal depends on the consumer's internal buffer state, creating a backpressure chain from output back to input.

---

## 3. Engineering Lessons

### 3.1 Constant-image immunity

A flat (constant) image passes through many buggy implementations because:
- All DCT AC coefficients are zero → many code paths not exercised
- Quantization is trivial (no overflow risk)
- Zigzag reordering doesn't matter (all values same)

**Lesson**: Always include content-rich images (gradient, noise, pattern) in your regression. The flat64 test alone would have missed 4 bugs in this project.

### 3.2 Line buffer design

The 4:2:0 decimation needs a line buffer to average vertically adjacent rows. Two approaches:
- **Single 2D array**: Vivado explodes it into flip-flops (can't infer RAM)
- **Per-row 1D arrays**: Each RAM gets exactly one write + one read port → infers as BRAM

The second approach was required because Vivado 2025.2 has a pathological elaboration path for 3-D packed RAMs of this shape.

### 3.3 Multiplication width

The quantization multiply (coefficient × reciprocal) requires careful width analysis:
- Coefficient: 11-bit signed (after DCT scaling)
- Reciprocal: up to 24-bit
- Product: up to 35-bit → a 27-bit register was insufficient and caused wraparound

**Lesson**: Always compute the exact bit-width of every intermediate. A "one bit should be enough" approach fails when the worst case is reached.

### 3.4 Deadlock in pipelined handshakes

When every stage uses valid/ready with double buffering, a deadlock can occur if the backpressure path has a circular dependency:
```
A waits for B to drain → B waits for C to drain → C waits for A's output
```

This was observed on the board (I-25) but not in simulation, because the timing was different. The fix requires careful analysis of the dependency graph to ensure no circular waits.

---

## 4. JPEG File Format

### 4.1 JFIF structure

```
FFD8          — SOI (Start of Image)
FFDB + tables — DQT (Quantization Tables)
FFC0 + params — SOF0 (Start of Frame: dimensions, sampling)
FFC4 + tables — DHT (Huffman Tables)
FFDA + params — SOS (Start of Scan)
<scan data>   — Entropy-coded data (with byte stuffing)
FFD9          — EOI (End of Image)
```

The hardware encoder produces only the scan data (entropy-coded bytes). Headers can be generated in software.

### 4.2 Byte stuffing

If the entropy encoder produces 0xFF followed by a bit that forms 0x00 in the next byte position, a 0x00 byte is stuffed after the 0xFF. This prevents premature detection of markers within the scan data.

---

## 5. Further Reading

- *JPEG: Still Image Data Compression Standard* — Pennebaker & Mitchell (the definitive reference)
- *Digital Image Processing* — Gonzalez & Woods (DCT theory, color spaces)
- ITU-T T.81 — JPEG specification (the actual standard document)
- *The Data Compression Book* — Nelson & Gailly (Huffman coding)
- libjpeg source code (jdct.h for the LLM DCT algorithm)
