#!/usr/bin/env python3
# diag_d1d2.py — 专门测试 D1/D2 能否写低
# 这两个脚是 MPSSE 的 TDI/TDO, 怀疑被强制拉高

import ftd2xx
import time

dev = ftd2xx.open(0)
dev.resetDevice()
dev.setBitMode(0x00, 0x02)
time.sleep(0.05)

def write_read(val):
    dev.write(bytes([0x80, val & 0xFF, 0xFF]))
    time.sleep(0.02)
    dev.purge(1)
    dev.write(bytes([0x81]))
    time.sleep(0.02)
    rd = dev.read(1)
    return rd[0] if isinstance(rd,(bytes,bytearray)) and len(rd) else -1

print("=== D0-D7 逐位写低测试 ===")
print("期望: 写某位 0, 该位回读应为 0")
print()
for bit in range(8):
    # 所有位写 1, 只把当前位写 0
    val = 0xFF & ~(1 << bit)
    rd = write_read(val)
    bit_read = (rd >> bit) & 1
    status = "OK" if bit_read == 0 else "FAIL(写0读1)"
    print(f"D{bit}: 写 0b{val:08b}, 读 0b{rd:08b}  -> D{bit}={bit_read} [{status}]")

print()
print("=== 专门测 D1/D2 组合 ===")
for val in [0x00, 0x01, 0x02, 0x04, 0x03, 0x05, 0x06]:
    rd = write_read(val)
    print(f"写 0b{val:08b} -> 读 0b{rd:08b}")

dev.write(bytes([0x80, 0x00, 0xFF]))
dev.close()
