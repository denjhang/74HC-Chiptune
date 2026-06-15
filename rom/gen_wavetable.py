#!/usr/bin/env python3
# gen_wavetable.py — 波表 ROM 生成器 (wt2 架构)
#
# 地址布局 (19-bit):
#   A18-A13: 0
#   A12-A11: wave_idx[1:0]  (4 种波形)
#   A10-A7:  vol[3:0]       (16 级音量)
#   A6-A0:   phase[6:0]     (128 点)
#
# 波形 (4 种):
#   0: 正弦 (sine)
#   1: 方波 (square)
#   2: 三角 (triangle)
#   3: 锯齿 (sawtooth)
#
# 音量缩放:
#   vol=0  → 振幅 0   (输出恒 128, 静音)
#   vol=15 → 振幅 127 (满幅, 8-bit 无符号)
#
# 输出值: 0..255 (8-bit 无符号, 128 = 中点)

import math

NUM_POINTS = 128
NUM_WAVES = 4
NUM_VOLS = 16

DAC_CENTER = 128   # 8-bit 无符号中点
DAC_MAX_AMP = 127  # vol=15 时最大振幅

def wave_sine(phase):
    """正弦: -1..+1 → 输出振幅 0..1"""
    return 0.5 - 0.5 * math.cos(2 * math.pi * phase / NUM_POINTS)

def wave_square(phase):
    """方波: 前 50% = +1, 后 50% = -1"""
    return 1.0 if phase < NUM_POINTS / 2 else 0.0

def wave_triangle(phase):
    """三角: 0→1→0 (前 50%), 0→0→0 反相 (后 50%)"""
    half = NUM_POINTS / 2
    if phase < half:
        return phase / half
    else:
        return (NUM_POINTS - phase) / half

def wave_sawtooth(phase):
    """锯齿: 0→1 线性上升"""
    return phase / NUM_POINTS

WAVE_FUNCS = [wave_sine, wave_square, wave_triangle, wave_sawtooth]
WAVE_NAMES = ["sine", "square", "triangle", "sawtooth"]

def amplitude_for_vol(vol):
    """vol=0→0, vol=15→127"""
    return DAC_MAX_AMP * vol / (NUM_VOLS - 1)

def sample_value(wave_idx, vol, phase):
    """计算 ROM 单元值 (0..255)"""
    amp = amplitude_for_vol(vol)
    if amp == 0:
        return DAC_CENTER
    wave = WAVE_FUNCS[wave_idx](phase)
    # wave 范围 0..1, 中点 0.5
    signed = (wave - 0.5) * 2 * amp  # -amp..+amp
    val = int(round(DAC_CENTER + signed))
    # 钳位 0..255
    if val < 0: val = 0
    if val > 255: val = 255
    return val

def rom_addr(wave_idx, vol, phase):
    """计算 ROM 地址 (19-bit)"""
    return ((wave_idx & 0x3) << 11) | ((vol & 0xF) << 7) | (phase & 0x7F)

def main():
    rom = bytearray(524288)  # 512KB

    # 默认填充 DAC_CENTER (静音), 防止未定义区域产生噪音
    for i in range(524288):
        rom[i] = DAC_CENTER

    # 写入有效区域 (4 wave × 16 vol × 128 point = 8192 字节)
    for wave_idx in range(NUM_WAVES):
        for vol in range(NUM_VOLS):
            for phase in range(NUM_POINTS):
                addr = rom_addr(wave_idx, vol, phase)
                rom[addr] = sample_value(wave_idx, vol, phase)

    with open("rom/wt3_wavetable.hex", "w") as f:
        for b in rom:
            f.write(f"{b:02X}\n")

    print(f"Written wt3_wavetable.hex ({len(rom)} bytes)")
    print(f"Used: {NUM_WAVES} waves × {NUM_VOLS} vols × {NUM_POINTS} points = "
          f"{NUM_WAVES * NUM_VOLS * NUM_POINTS} bytes")
    print()
    print("Wave preview (vol=15, first 16 points):")
    for wave_idx in range(NUM_WAVES):
        vals = [sample_value(wave_idx, NUM_VOLS - 1, p) for p in range(16)]
        print(f"  wave={wave_idx} ({WAVE_NAMES[wave_idx]:<10}): {vals}")

    print()
    print("Volume scaling (sine wave, phase=0):")
    for vol in range(NUM_VOLS):
        val = sample_value(0, vol, 0)
        print(f"  vol={vol:2d}: amp={amplitude_for_vol(vol):6.2f}, value={val}")

    print()
    print("Volume scaling (sine wave, phase=64 = peak):")
    for vol in range(NUM_VOLS):
        val = sample_value(0, vol, 64)
        print(f"  vol={vol:2d}: value={val}")

if __name__ == "__main__":
    main()
