# k5p-jpeg-encoder

Kintex UltraScale+ **xcku5p-ffvb676-2-i** 上的 Baseline JPEG 静态图像编码器内核。
RGB888 光栅 → JFIF 熵编码字节流,**与 golden 定点模型逐字节一致**。
纯 RTL,单时钟,全 valid/ready 握手,任意背压安全。

## 结果一览

| 验证项 | 结果 |
|--------|------|
| tb_fdct1d(1-D DCT,随机 2000 矢量 × 两 pass) | PASS |
| tb_gather(MCU 组装,4 图,96/96/96/288 块) | 0 误差 |
| tb_decim(4:2:0 隔离单测,4 图,随机双侧背压) | 0 误差 |
| tb_huff(熵编码单元,4 图,含 0xFF 塞字节/帧尾 pad) | 0 误差 |
| **tb_jpeg_top(整核端到端,字节精确对拍 golden)** | **10 图 0 误差**(含 4 张随机图) |
| OOC 综合 xcku5p @ 100 MHz | TIMING_MET(WNS +3.94 / WHS +0.03 / 0 critDRC) |

端到端输出字节数:flat64=67、grad64=236、noise64=1658、pat128x96=1156、
rnd1=1665、rnd2=2518、rnd3=2512、rnd4=3359 —— 与 golden 逐字节一致
(含帧尾 1 位填充字节与 out_last)。

golden 模型可信度:整数量化与截断除法 2,097,024 例全等;FDCT 与浮点参考
≤2 LSB;golden JFIF 经 PIL 解码与 libjpeg 编码同图 PSNR 一致。

## 为什么是 JPEG(选型理由)

- **匹配板子**:UltraScale+ 的 DSP/BRAM 对 8x8 DCT + 行缓冲是甜点负载,
  不依赖软核/外部存储,上板即所见即所得。
- **含金量**:JPEG 编码覆盖色彩空间转换、抽样、整数变换、量化、游程+Huffman、
  位打包——一条完整的信号处理+协议栈,面试可讲的层比"点个 IP"多得多。
- **可验证性**:golden 定点模型可以做到**逐字节对拍**,比"仿真不报错"强一个量级。
- 已排除的备选:PCIe/10G MAC(ModelSim 缺 IP 仿真库)、DDR4 MIG(同)、
  RISC-V 核/视频处理(与既有项目重复)。

## 仓库结构

```
rtl/    jpeg_top.v  rgb2ycbcr.v  decim420.v  mcu_gather.v
        fdct1d_llm.v  dct2d.v  quant.v  huff_enc.v
tb/     tb_jpeg_top.sv  tb_huff.sv  tb_gather.sv  tb_decim.sv  tb_fdct1d.sv
golden/ jpeg_golden.py(定点参考模型) gen_vectors.py  gen_mid.py
        gen_huffbytes.py  jpeg_decode_check.py  cmp_huff_stream.py
vectors/ 4 张测试图 + 全部 golden 对拍文件
sim/    ModelSim 工作库
scripts/synth_ooc.tcl(xcku5p OOC 综合 + 100 MHz 时序检查)
docs/   DESIGN.md  LOG.md  ISSUES.md
*.mem   zigzag / Annex K 码表 / 量化倒数表(供 $readmemh,CWD=项目根)
```

## 复现

```bash
# 生成 golden(需 Python3,PIL 可选)
python golden/gen_vectors.py && python golden/gen_mid.py && python golden/gen_huffbytes.py

# ModelSim(项目根 = CWD,mem 文件在这里)
cd <项目根>
vsim -c -do "vlog rtl/*.v tb/*.sv; vopt work.tb_jpeg_top -o j +acc; \
             vsim -c work.j +TAG=noise64; run -all; quit -f"
# TB 标签:flat64 / grad64 / noise64 / pat128x96

# OOC 综合 + 时序(100 MHz)
vivado -mode batch -source scripts/synth_ooc.tcl    # 结果在 results/ooc_*.rpt
```

注意:ModelSim 需用 `vlog` + `vopt -o <新名>` 显式重究化,直接 `vsim` 可能
复用旧 `_opt` 缓存(见 docs/ISSUES.md 探针方法论第 5 条)。

## 上板说明(交给后续)

- 引脚与时序约束随板;内核 OOC 时序结果见 results/ooc_timing.rpt。
- 输入侧需要 DMA/相机源提供 RGB 光栅 + 行/帧边界;输出字节流接缓存或
  直接进以太网/SDR。单帧一次编码,多帧需在帧间拉 rst(文档化取舍,见 DESIGN.md)。

## 文档

- [docs/DESIGN.md](docs/DESIGN.md) -- 架构、模块契约、数值域约定、实时性预算
- [docs/ISSUES.md](docs/ISSUES.md) -- 21 个调试问题的台账与"探针方法论"沉淀
- [docs/LOG.md](docs/LOG.md) -- 按日期的工作日志
