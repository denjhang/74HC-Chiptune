#!/usr/bin/env python3
# gen_roms.py - 生成测试用的 ROM 文件

import os

# 程序 ROM (8-bit 数据)
# 简单测试：输出 0-255 循环
prog_rom = bytearray(range(256))

# 数据 ROM (16-bit 数据)
# 测试：正弦波 256 点
import math
data_rom = bytearray()
for i in range(65536):
    # 生成正弦波 (256 点循环)
    value = int(127.5 + 127.5 * math.sin(2 * math.pi * i / 256))
    data_rom.append(value & 0xFF)
    data_rom.append(0x00)  # 高字节 (待用)

# 截取前 64KB (实际 ROM 大小)
data_rom = data_rom[:65536]

# 写入 hex 文件
os.makedirs("rom", exist_ok=True)

with open("rom/fsm_prog.hex", "w") as f:
    for i in range(0, len(prog_rom), 16):
        chunk = prog_rom[i:i+16]
        f.write(" ".join(f"{b:02x}" for b in chunk) + "\n")

with open("rom/fsm_data.hex", "w") as f:
    for i in range(0, len(data_rom), 16):
        chunk = data_rom[i:i+16]
        f.write(" ".join(f"{b:02x}" for b in chunk) + "\n")

print("Generated rom/fsm_prog.hex (8-bit, 256 bytes)")
print("Generated rom/fsm_data.hex (8-bit, 64KB)")
print("Data ROM contains sine wave pattern")
