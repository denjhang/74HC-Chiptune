#!/usr/bin/env python3
# diag_gate_hold.py — 诊断: gate 持续开, 只写一次 period, 看是否有持续音
# 如果只有写瞬间响(敲击) = clk 没接, PSG 不振荡
# 如果持续响 = 正常

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

print("=== 诊断: clk 是否工作 ===")
# 复位
sc(BIT_RST, 0); sc(BIT_RST, 1)

# 测试1: gate 开着, 写 A4 period, 然后什么都不做, 持续 3 秒
print("[测试1] 写 A4(440Hz), gate 持续开 3 秒")
print("  期望: 如果 clk 正常, 应持续听到 440Hz 纯音")
print("  如果只有开头嗒一声 = clk 没接")
sc(BIT_GATE, 1)  # 先开 gate
_d = 114  # A4 period
dev.write(bytes([0x80, _d, 0xFF])); time.sleep(2e-3)
sc(BIT_LE, 1); sc(BIT_LE, 0)  # LE 脉冲锁存
print("  >>> period 已锁存, gate 已开, 现在静等 3 秒...")
time.sleep(3)

print("[测试2] 反复开关 gate (不写 period), 每次开 0.3 秒")
print("  如果每次开 gate 都嗒一声 = 还是没振荡 (gate 跳变毛刺)")
print("  如果开 gate 有持续音 = 正常")
for i in range(5):
    sc(BIT_GATE, 1); time.sleep(0.3)
    sc(BIT_GATE, 0); time.sleep(0.2)

# 收尾
sc(BIT_GATE, 0); _c = 0; _d = 0; w()
dev.close()
print("完成")
