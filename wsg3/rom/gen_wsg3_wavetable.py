#!/usr/bin/env python3
# gen_wsg3_wavetable.py — Pac-Man 风格 8×32 波形表
# 8 种波形 (0-7), 每种 32 点, 4-bit 幅度

import struct

# 8 种波形定义 (32 点, 0-15 幅度)
def sine_wave():
    import math
    return [int(8 + 7 * math.sin(2 * math.pi * i / 32)) for i in range(32)]

def square_wave():
    return [15 if i < 16 else 0 for i in range(32)]

def triangle_wave():
    return [min(i, 31-i) for i in range(32)]

def sawtooth_wave():
    return [i for i in range(32)]

def noise_wave():
    import random
    random.seed(42)
    return [random.randint(0, 15) for _ in range(32)]

def empty_wave():
    return [0] * 32

# 生成 8 种波形
waves = [
    sine_wave(),      # 0: sine
    square_wave(),    # 1: square
    triangle_wave(),  # 2: triangle
    sawtooth_wave(),  # 3: sawtooth
    noise_wave(),     # 4: noise
    empty_wave(),     # 5: unused
    empty_wave(),     # 6: unused
    empty_wave(),     # 7: unused
]

# 按 Pac-Man 格式: 每个波形占 32 字节, 顺序排列
rom_data = []
for wave in waves:
    rom_data.extend(wave)

# 写 hex 文件 (每行一个字节, hex 格式)
with open('wsg3_wavetable.hex', 'w') as f:
    for byte in rom_data:
        f.write(f'{byte:02X}\n')

print(f'Generated wsg3_wavetable.hex: {len(rom_data)} bytes (8 waves × 32 points)')
