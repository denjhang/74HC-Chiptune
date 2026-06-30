#!/usr/bin/env python3
# diag_long.py — 长时间诊断 (每阶段拉长, 听清楚)
#
# 测试1: gate 持续开 8 秒, 只写一次 A4 period
#   持续响 = 正常; 只开头响 = toggle 没翻转
# 测试2: 不写 period, 只开关 gate, 每次开 1.5 秒
#   每次开都持续响 = gate 电路正常; 只有嗒声 = 无振荡
# 测试3: 写不同 period (A3/A4/A5), gate 持续开, 每音 2 秒
#   能听出音高变化 = period 通路正常

import ftd2xx
import time

BIT_LE, BIT_GATE, BIT_RST = 0, 1, 2
CLK_HZ = 125_000

dev = ftd2xx.open(0)
dev.resetDevice()
dev.setBitMode(0x00, 0x02)
time.sleep(0.05)
_c = 0; _d = 0

def w():
    dev.write(bytes([0x80, _d & 0xFF, 0xFF]))
    dev.write(bytes([0x82, _c & 0xFF, 0xFF]))
    time.sleep(2e-3)

def sc(bit, v):
    global _c
    if v: _c |= (1 << bit)
    else: _c &= ~(1 << bit)
    dev.write(bytes([0x82, _c & 0xFF, 0xFF]))
    time.sleep(2e-3)

def write_period(p):
    global _d
    _d = max(0, min(255, p)) & 0xFF
    dev.write(bytes([0x80, _d, 0xFF])); time.sleep(2e-3)
    sc(BIT_LE, 1); sc(BIT_LE, 0)

print("=== 长时间诊断 (每阶段拉长) ===\n")

# 复位
sc(BIT_RST, 0); time.sleep(5e-3); sc(BIT_RST, 1); time.sleep(5e-3)

print("[测试1] 写 A4(440Hz), gate 持续开 8 秒")
print("  >>> 听: 持续嗡嗡 = 正常; 只开头嗒一声 = 振荡有问题")
write_period(114)   # A4
sc(BIT_GATE, 1)
time.sleep(8)
sc(BIT_GATE, 0)
time.sleep(1)

print("\n[测试2] 不写 period, 只开关 gate 5 次, 每次 1.5 秒")
print("  >>> 听: 每次开都有持续音 = gate+振荡正常; 只嗒 = 无振荡")
for i in range(5):
    sc(BIT_GATE, 1); time.sleep(1.5)
    sc(BIT_GATE, 0); time.sleep(0.5)
time.sleep(1)

print("\n[测试3] 写不同 period, gate 持续开, 每音 2.5 秒")
print("  >>> 听: 三个音音高不同 = period 通路正常")
for name, p in [("A3", 77), ("A4", 114), ("A5", 185)]:
    write_period(p)
    sc(BIT_GATE, 1)
    print(f"  {name} period={p}...", flush=True)
    time.sleep(2.5)
    sc(BIT_GATE, 0)
    time.sleep(0.3)

# 收尾
sc(BIT_GATE, 0); _c = 0; _d = 0; w()
dev.close()
print("\n完成")
