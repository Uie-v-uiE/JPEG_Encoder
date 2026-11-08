# -*- coding: utf-8 -*-
"""JPEG 板级自动验证:开 COM6 监听 → 烧 jpeg_demo_board.bit → 收 67 字节
→ 与 vectors/gold_flat64_scan.hex 逐字节比对。"""
import serial
import subprocess
import sys

GOLD = r'D:/Xilinx/Harness/Project/new_prj/k5p-jpeg-encoder/vectors/gold_flat64_scan.hex'
BIT = r'D:/Xilinx/Harness/Project/new_prj/k5p-jpeg-encoder/build/jpeg_board/jpeg_board/jpeg_board.runs/impl_1/jpeg_demo_board.bit'

# gold:每行 hex 一字节
gold = bytearray()
for ln in open(GOLD):
    ln = ln.strip()
    if ln:
        gold.append(int(ln, 16))
print("gold bytes = %d" % len(gold))

# 1) 打开串口(先于烧写,不漏首字节)
ser = serial.Serial('COM6', 115200, bytesize=8, parity='N', stopbits=1, timeout=30)
ser.reset_input_buffer()
print("COM6 opened @115200")

# 2) 烧写(阻塞直到完成)
r = subprocess.run([
    r'D:/Software/Vivado/2025.2.1/Vivado/bin/vivado.bat', '-mode', 'batch',
    '-source', r'D:/Xilinx/Harness/Project/new_prj/k5p-jpeg-encoder/scripts/program_jpeg.tcl', '-nojournal', '-notrace',
    '-log', '/tmp/program_jpeg.log'], capture_output=True, text=True, timeout=600)
ok = 'PROGRAMMED JPEG OK' in (r.stdout or '')
print("program rc=%s ok=%s" % (r.returncode, ok))
if not ok:
    print((r.stdout or '')[-800:])
    sys.exit(1)

# 3) 收 N 倍(演示可能上电即发 + 之后的按键重启;收首个完整 67 字节块)
got = bytearray()
need = len(gold)
while len(got) < need:
    b = ser.read(need - len(got))
    if not b:
        print("TIMEOUT: got %d/%d bytes" % (len(got), need))
        break
    got.extend(b)
ser.close()

print("received %d bytes" % len(got))
print("hex :", got.hex())
n_ok = sum(1 for a, b in zip(got, gold) if a == b)
print("compare: %d/%d bytes match" % (n_ok, need))
if got[:need] == gold:
    print("JPEG UART VERIFY: PASS (byte-exact vs gold_flat64_scan)")
else:
    print("JPEG UART VERIFY: FAIL")
    for i, (a, b) in enumerate(zip(got, gold)):
        if a != b:
            print("  first diff @%d: got %02X exp %02X" % (i, a, b))
            break
