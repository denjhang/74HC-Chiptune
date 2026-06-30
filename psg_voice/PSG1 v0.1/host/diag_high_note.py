#!/usr/bin/env python3
# diag_high_note.py — 诊断高音消失: 逐个测 C4/C5/C6/C7, 每个响 2 秒
# 如果某个音开始没声音 = 找到极限点

import ftd2xx
import time

BIT_LE, BIT_GATE, BIT_RST = 4, 5, 6
CLK_HZ = 16700

dev = ftd2xx.open(0)
dev.resetDevice()
dev.setBitMode(0x00, 0x02)
time.sleep(0.05)
_d = 0; _c = 0
dev.write(bytes([0x80, 0x00, 0xFF]))
dev.write(bytes([0x82, 0x00, 0xFF]))
time.sleep(2e-3)

def sd(bit, v):
    global _d
    if v: _d |= (1 << bit)
    else: _d &= ~(1 << bit)
    dev.write(bytes([0x80, _d & 0xFF, 0xFF]))
    time.sleep(2e-3)

def freq(f):
    global _c
    p = max(0, min(255, round(256 - CLK_HZ / (2 * f))))
    steps = 256 - p
    _c = p & 0xFF
    dev.write(bytes([0x82, _c, 0xFF])); time.sleep(2e-3)
    sd(BIT_LE, 1); sd(BIT_LE, 0)
    return p, steps

sd(BIT_RST, 0); time.sleep(2e-3); sd(BIT_RST, 1); time.sleep(2e-3)

print("=== 高音消失诊断 (每音 2 秒) ===")
print("音  频率    period  计数步数  实际频率")
tests = [('C3',130.8),('C4',261.6),('C5',523.3),('C6',1046.5),('C7',2093),('C8',4186)]
for name, f in tests:
    p, steps = freq(f)
    actual = CLK_HZ / (2 * steps) if steps > 0 else 0
    print(f"{name} {f:7.1f}Hz  period={p:3}  步数={steps:2}  实际{actual:.0f}Hz  <-响2秒", flush=True)
    sd(BIT_GATE, 1)
    time.sleep(2)
    sd(BIT_GATE, 0)
    time.sleep(0.3)

_d = 0; _c = 0
dev.write(bytes([0x80, 0x00, 0xFF]))
dev.write(bytes([0x82, 0x00, 0xFF]))
dev.close()
print("\n完成. 告诉我从哪个音开始没声音.")
