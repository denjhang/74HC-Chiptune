#!/usr/bin/env python3
# diag_period_change.py — 诊断: 写不同 period, 回读 D 口确认数据变化
# 如果 D 口回读值不变 = FT232H 没写出去
# 如果 D 口回读变了但声音不变 = LS373/HC373 锁存问题

import ftd2xx
import time

BIT_LE, BIT_GATE, BIT_RST = 0, 1, 2

dev = ftd2xx.open(0)
dev.resetDevice()
dev.setBitMode(0x00, 0x02)
time.sleep(0.05)
_c = 0; _d = 0
dev.write(bytes([0x80, 0x00, 0xFF]))
dev.write(bytes([0x82, 0x00, 0xFF]))
time.sleep(2e-3)

def write_d(val):
    """写 D 口并回读验证."""
    dev.write(bytes([0x80, val & 0xFF, 0xFF]))
    time.sleep(0.01)
    # 回读 D 口
    dev.purge(1)
    dev.write(bytes([0x81]))
    time.sleep(0.01)
    rd = dev.read(1)
    rd = rd[0] if isinstance(rd,(bytes,bytearray)) and len(rd) else -1
    return rd

def sc(bit, v):
    global _c
    if v: _c |= (1 << bit)
    else: _c &= ~(1 << bit)
    dev.write(bytes([0x82, _c & 0xFF, 0xFF]))
    time.sleep(2e-3)

# 复位
sc(BIT_RST, 0); time.sleep(2e-3); sc(BIT_RST, 1); time.sleep(2e-3)

print("=== period 数据变化诊断 ===")
print("写不同 period, 回读 D 口, 同时开 gate 让它响 1 秒\n")

tests = [
    ('C4', 17),   ('D4', 43),   ('E4', 67),
    ('A4', 114),  ('C5', 137),  ('A5', 185),  ('C6', 196),
]

for name, p in tests:
    # 写 D 口
    rd = write_d(p)
    # LE 脉冲锁存
    sc(BIT_LE, 1); sc(BIT_LE, 0)
    # 开 gate 响 1 秒
    sc(BIT_GATE, 1)
    match = "OK" if rd == p else f"FAIL(读到0x{rd:02x})"
    print(f"{name} period={p:3} (0x{p:02x}) -> D口回读=0x{rd:02x} [{match}]  <-响1秒", flush=True)
    time.sleep(1)
    sc(BIT_GATE, 0)
    time.sleep(0.2)

_c = 0; _d = 0
dev.write(bytes([0x80, 0x00, 0xFF]))
dev.write(bytes([0x82, 0x00, 0xFF]))
dev.close()
print("\n完成")
