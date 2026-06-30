#!/usr/bin/env python3
# diag_cport.py — 测 C 口(0x82命令)写各种值是否可靠
# 特别测大值 (C5 period=240=0xF0 附近)
# 怀疑 C 口高 bit 写入有问题导致 C5+ period 错误

import ftd2xx
import time

dev = ftd2xx.open(0)
dev.resetDevice()
dev.setBitMode(0x00, 0x02)
time.sleep(0.05)

def write_c_read(val):
    """写 C 口并回读."""
    dev.write(bytes([0x82, val & 0xFF, 0xFF]))
    time.sleep(0.02)
    dev.purge(1)
    dev.write(bytes([0x83]))
    time.sleep(0.02)
    rd = dev.read(1)
    return rd[0] if isinstance(rd,(bytes,bytearray)) and len(rd) else -1

print("=== C 口(0x82) 写入可靠性测试 ===")
print("测各个 period 值对应的数据, 重点 C4-C8 范围\n")

tests = [
    ('C3 period', 192), ('C4 period', 224), ('C5 period', 240),
    ('C6 period', 248), ('C7 period', 252), ('C8 period', 254),
    # 逐 bit 测
    ('bit0 only', 0x01), ('bit4 only', 0x10), ('bit7 only', 0x80),
    ('all 1', 0xFF), ('all 0', 0x00),
    # 临界值
    ('val 240', 240), ('val 241', 241), ('val 242', 242), ('val 243', 243), ('val 244', 244), ('val 245', 245),
]

for name, val in tests:
    rd = write_c_read(val)
    match = "OK" if rd == val else f"FAIL(写0x{val:02x}读0x{rd:02x})"
    print(f"{name:12} 写 0x{val:02x} ({val:3}) -> 读 0x{rd:02x} ({rd:3}) [{match}]")

dev.write(bytes([0x82, 0x00, 0xFF]))
dev.close()
