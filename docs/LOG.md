# LOG -- k5p-jpeg-encoder

## 2026-11-05

- 项目立项:选型 KU5P JPEG 编码器(决策理由见 README"为什么是 JPEG")。
- golden 定点模型 `jpeg_golden.py`:JFIF 整数 YCbCr、4:2:0、jfdctint、
  精确倒数量化、Annex K 码表(从 libjpeg 产出的 JPEG 解析 DHT 得到)。
  自检:FDCT vs 浮点 ≤2 LSB;量化 vs 截断除法 2,097,024 例全等;
  PIL 解码 PSNR 与 libjpeg 同图一致。
- 4 张测试图(flat64/grad64/noise64/pat128x96)+ 分级中间文件生成器。
- RTL 全部 8 个模块写完。

## 2026-11-05 深夜 ~ 11-06 凌晨(调试马拉松)

- tb_fdct1d 2000 矢量 PASS(修 I-01/I-04)。
- tb_gather 4 图 PASS(修 decim 侧 s_eol 分支、读址、位宽等)。
- dct2d 状态机多轮修复(I-02/I-03)。
- tb_huff:2 字节卡死 → wslot 越界(I-08)→ pad 错误(I-09)→
  zigzag 双重应用(单位 TB 喂错序)→ **4 图 PASS**。
- tb_jpeg_top:flat 过内容图挂 → 分层探针逐级击破:
  I-13(Y+128)→ I-10/I-12(幽灵拍/共享索引)→ I-14/I-15(1 深竞态/指针越界)
  → I-16/I-17(decim 读址冻结/sof 两重错)→ I-18(窗口覆盖)
  → I-19(投影容量闸)→ I-20(量化组偏移)→ I-21(eof 侧带位宽)
  → **4 图字节精确 PASS**。

## 2026-11-06

- 新增 tb_decim(4:2:0 隔离单测,双侧随机背压),4 图 PASS。
- 清除全部调试显示,17/17 回归全绿(fdct1d 2000 + gather/huff/decim/jpeg_top 各 4 图)。
- 最终回归输出(摘录):

```
tb_fdct1d: checked=2000 errors=0 -> PASS
tb_gather tag=flat64:    y=4096  c=1024 blocks=96  errors=0 -> PASS   (×4 图)
tb_huff   tag=noise64:   blocks=96 bytes=1657 errors=0 -> PASS          (×4 图)
tb_decim  tag=pat128x96: sent=12288 chroma=3072 errors=0 -> PASS        (×4 图)
tb_jpeg_top tag=flat64:    sent=4096  bytes=67   errors=0 -> PASS
tb_jpeg_top tag=noise64:   sent=4096  bytes=1658 errors=0 -> PASS
tb_jpeg_top tag=grad64:    sent=4096  bytes=236  errors=0 -> PASS
tb_jpeg_top tag=pat128x96: sent=12288 bytes=1156 errors=0 -> PASS
```

- Vivado OOC 综合(xcku5p-ffvb676-2-i,100 MHz 目标)启动。
- 文档(README/DESIGN/LOG/ISSUES)成稿,git 提交。

## 2026-11-07(审查轮)

- 双代理代码审查(P2/P1 各一)。P2 侧 3 个 P0 全部证实并修复:
  I-23(huff pad 同拍覆盖)、I-24(quant 乘积回绕)、I-22(gather RAM 推断);
  新增 I-29/I-32(综合脚本两坑)与 I-33(双 always 多驱动)。
- 回归扩到 10 图(flat64/grad64/noise64/pat128x96 + rnd1-4 随机),
  tb_huff/tb_jpeg_top 10/10 PASS。
- OOC 综合(xcku5p-ffvb676-2-i,100 MHz)最终收敛:
  WNS=+3.941 / WHS=+0.026 / 0 critDRC / 全实例在网表 / 600 LUTRAM 行缓冲。
  (三次失败教训:陈旧项目网表、readmemh CWD、双 always 多驱动——见 ISSUES。)
- P2 git 提交完成。
