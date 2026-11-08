#!/usr/bin/env python3
"""KU5P JPEG board bring-up capture: open COM @115200, JTAG-program the
device (reconfiguration restarts the demo), capture the entropy byte
stream, and compare byte-exact with vectors/gold_flat64_scan.hex."""
import sys, time, subprocess, glob

import serial

ROOT = r"D:\Xilinx\Harness\Project\new_prj\k5p-jpeg-encoder"
BIT  = ROOT + r"\build\jpeg_board\jpeg_board.runs\impl_1\jpeg_demo_board.bit"
GOLD = ROOT + r"\vectors\gold_flat64_scan.hex"
VIVADO = r"D:\Software\Vivado\2025.2.1\Vivado\bin\vivado.bat"
PROG_TCL = ROOT + r"\scripts\prog_ku5p.tcl"

def pick_port():
    ports = sorted(glob.glob(r"\.\COM*"))
    if len(ports) == 1:
        return ports[0]
    return ports

def main():
    gold = [int(l, 16) for l in open(GOLD) if l.strip()]
    print("golden bytes:", len(gold))

    cands = pick_port()
    print("candidate ports:", cands)
    # take the LAST one (highest COM number = most recently enumerated)
    port = cands[-1]
    print("using", port)

    ser = serial.Serial(port, 115200, timeout=0.2)
    ser.reset_input_buffer()

    # JTAG program (reconfiguration restarts the demo FSM)
    r = subprocess.run([VIVADO, "-mode", "batch", "-source", PROG_TCL],
                       capture_output=True, text=True, timeout=180)
    prog_ok = ("Programming succeeded" in (r.stdout or "") or
               "Programming succeeded" in (r.stderr or ""))
    print("program ok:", prog_ok)

    # capture
    data = bytearray()
    t0 = time.time()
    while time.time() - t0 < 4.0:
        chunk = ser.read(256)
        if chunk:
            data.extend(chunk)
    ser.close()

    print("captured bytes:", len(data))
    n = len(gold)
    got = list(data[:n])
    mism = [(i, got[i], gold[i]) for i in range(min(n, len(got))) if got[i] != gold[i]]
    if len(data) < n:
        print("RESULT: FAIL (short stream: %d < %d)" % (len(data), n))
    elif len(data) > n:
        print("RESULT: FAIL (extra bytes: %d > %d)" % (len(data), n))
    elif mism:
        print("RESULT: FAIL (%d mismatches, first: %s)" % (len(mism), mism[:4]))
    else:
        print("RESULT: PASS -- %d bytes byte-exact" % n)
    print("first 8:", " ".join("%02x" % b for b in data[:8]))
    print("last  8:", " ".join("%02x" % b for b in data[-8:]))

if __name__ == "__main__":
    main()
