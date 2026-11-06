# DESIGN -- k5p-jpeg-encoder

Kintex UltraScale+ (xcku5p-ffvb676-2-i) 上的 Baseline JPEG 编码器内核。
RGB888 光栅输入,JFIF 熵编码字节流输出,与 golden 定点模型**逐字节一致**。

## 总体架构

```
cfg(W,H) ────────────────────────────────┐
RGB888 ──► fifo4 ──► rgb2ycbcr ──► decim420 ──► mcu_gather ──► dct2d ──► quant ──► huff_enc ──► 字节流
 (24b)     4 深      JFIF 整数      4:2:0        MCU 块序       jfdctint   精确倒数   Annex K
                    YCbCr 流水     2x2 均值      组装           整数 FDCT   乘法量化   Huffman
```

- **单时钟域**,全 valid/ready 握手,任意背压安全。
- 逐级 8 像素/系数并行(块列/系数行 8 组一拍),DCT 核 1 矢量/拍复用。

## 模块契约

| 模块 | 输入 → 输出 | 关键点 |
|------|------------|--------|
| `rgb2ycbcr` | RGB → Y/Cb/Cr 每像素 | 3 拍 uniform-stall;Y 带 +128 round-half-up(golden rgb2y),Cb/Cr floor(golden rgb2cb/cr) |
| `decim420` | 逐像素 Y/Cb/Cr → Y 直通 + 半速率 2x2 均值色度 | 行缓冲只存偶行 pair;奇行完成时 (偶行 pair + 奇行 pair) >> 2;4 深输出 FIFO;**偶列采样拍预读 lbuf**(I-16),sof 消耗列槽(I-17) |
| `mcu_gather` | Y/色度流 → MCU 块列流(Y0Y1Y2Y3CbCr × MCU 栅格) | 16 行 Y + 8 行色度乒乓;1 列/拍 9 拍/块;**pending_emit 即停输入**(I-18) |
| `dct2d` | 块列流 → 自然序系数流 | 双 slot:FILL→P1(列变换)→P1D→P2(行变换);共享 fdct1d 核(P1 优先);**每 pass 用自有进度寄存器收尾**(I-10/I-12);系数出口 **2 深 FIFO + 投影容量闸**(I-14/I-19) |
| `quant` | 自然序系数 → 量化系数(自然序) | 3 拍;表 = 精确倒数乘法 (M,S),**索引 {组号,lane}**(I-20);VQ_MAX=1151 保证 (|v|>>3 ≤ 1151) 内与截断除法逐位一致 |
| `huff_enc` | 量化块(zigzag 顺序,引擎内 ZZ ROM)→ 熵编码字节 | 双块乒乓 slot;1 系数/拍;DC 差分预测跨块跨分量;0xFF 塞字节;**wslot 翻转**(I-08);帧尾 pad = (-n) mod 8(I-09);字节级 final 标志覆盖 fstate 1/2 |

### 数值域关键约定

- **FDCT**:jfdctint(LL&M),CONST_BITS=13 / PASS1_BITS=2,列优先两遍
  (与 golden 同序,行优先差 ±1 LSB —— golden 按列优先对拍)。
  8 位输入下 |FDCT| ≤ 8191 ⇒ |v|>>3 ≤ 1151 = VQ_MAX。
- **量化**:round-half-away 除 8Q,等价于 `((|v|+4Q)>>3) × M' >> S'`;
  每个系数的 (M',S') 按精确性条件 `(VQ_MAX-1)·e·Q < 2^S'` 选最小 S'。
- **字节序**:MSB first,0xFF 后塞 0x00;帧尾不足 8 位按 1 填满。
- **顺序链**:dct2d 输出自然序 → quant 自然序表 → huff 内部 ZZ ROM 做 zigzag。
  golden q 文件是 zigzag 序,单位 TB 必须先反变换(踩过双重 zigzag)。

## 实时性预算

- gather 9 拍/块、54 拍/MCU → 1080p60(8100 MCU/帧)需 ≥ 26 MHz(流水化取数)。
- huff 引擎最坏 ~4 拍/系数(advance_ok 限积压 ≤16 位)⇒ 100 MHz 时约
  1.56 M 系数/s:720p60/1080p30 实时,1080p60 需 ~140 MHz。
- dct2d 双 slot:P1(N+1) 与 P2(N) 交错,系数 2 深 FIFO 吸收 1 拍背压抖动。

## 验证策略

| 层 | TB | 对拍物 |
|----|----|--------|
| 1-D FDCT | tb_fdct1d | golden fdct1d,2000 随机矢量,两 pass 各半 |
| MCU 组装 | tb_gather | golden 像素块,4 图 |
| 4:2:0 | tb_decim | golden decim 逐样本,随机双侧背压 |
| 熵编码 | tb_huff | golden 逐块字节流,4 图 |
| 整核 | tb_jpeg_top | golden JFIF 扫描字节,4 图,随机 valid 间隙 + 输出背压 |

golden 链:`jpeg_golden.py`(定点模型,与 libjpeg 输出 PIL 解码 PSNR 一致)
→ `gen_vectors.py`(4 图 + 扫描)/ `gen_mid.py`(分级中间文件)/
`gen_huffbytes.py`(逐块熵流)。中间文件让每级都能独立对拍——本项目的
20+ 个 bug 几乎全部由此分层击破(见 ISSUES.md 探针方法论)。

## 已知限制

- 单帧一次:DC 预测器仅 rst 清零,连续多帧需重置(文档化取舍)。
- 宽度需 16 的倍数(4:2:0 + MCU 对齐);MAX_W=1920 参数化行缓冲。
- tb_decim 的 cfg 未断言(W 保持 0,f_eol 在单测中不检查)——数据路径已覆盖。
