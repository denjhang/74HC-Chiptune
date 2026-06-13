#!/usr/bin/env python3
# gen_rom.py — 生成 74HC-Chiptune 的两片 39SF040 ROM
#
# 架构:
#   3 通道, 20-bit phase, 无硬件包络
#   波表 ROM: wave_idx × vol × phase 一次查表, 零运算
#
# ROM1 (指令 ROM): 32 步微程序控制信号 (8-bit)
#   3 通道 × 8 步 = 24 步 + 8 空闲 = 32 步循环
#   96kHz = 3.072MHz / 32
#   voice_sel = step[4:3], param_addr = step[2:0], 从硬件推导
#   ROM 只存 6 个控制使能信号
#
# ROM2 (波表 ROM): wave × vol 预计算查找表
#   地址 = {wave[2:0], vol[3:0], phase[19:12]} (15-bit)
#   共 8 × 16 × 256 = 32768 字节 (32KB)

import math

# ============================================================
# 波形定义 (128 点, 4-bit 无符号, 范围 0-15)
# ============================================================
N = 128

def make_sine(n=N):
    return [max(0, min(15, round(8 + 7 * math.sin(2 * math.pi * i / n)))) for i in range(n)]

def make_square(n=N):
    return [15 if i < n // 2 else 0 for i in range(n)]

def make_sq12(n=N):
    return [15 if i < n // 8 else 0 for i in range(n)]

def make_sq25(n=N):
    return [15 if i < n // 4 else 0 for i in range(n)]

def make_saw(n=N):
    return [max(0, min(15, round(15 * i / (n - 1)))) for i in range(n)]

def make_triangle(n=N):
    return [max(0, min(15, round(15 * (1 - abs(2 * i / n - 1))))) for i in range(n)]

def make_noise(n=N):
    import random
    rng = random.Random(42)
    return [rng.randint(0, 15) for _ in range(n)]

def make_sine2x(n=N):
    return [max(0, min(15, round(8 + 7 * math.sin(4 * math.pi * i / n)))) for i in range(n)]

WAVES = [make_sine, make_square, make_sq12, make_sq25, make_saw, make_triangle, make_noise, make_sine2x]
WAVE_NAMES = ["sine", "square", "sq12", "sq25", "saw", "triangle", "noise", "sine2x"]

# ============================================================
# 频率步进
# ============================================================
SAMPLE_RATE = 96000

def freq_to_step(freq):
    return round(freq * (1 << 19) / SAMPLE_RATE)

NOTE_FREQS = {
    'C4': 261.63, 'D4': 293.66, 'E4': 329.63, 'F4': 349.23,
    'G4': 392.00, 'A4': 440.00, 'B4': 493.88, 'C5': 523.25,
}

# ============================================================
# 生成指令 ROM (32 步, 8-bit 控制字)
# ============================================================
def gen_instruction_rom():
    """
    32 步循环 (5-bit hc161 × 2 = 0-31)
    96kHz = 3.072MHz / 32

    每通道 8 步:
      0: 清零加法器 + 累加 nib0
      1-4: 累加 nib1-4
      5: 读 vol
      6: 读 wave
      7: ROM 查表 + 混音锁存

    通道分配:
      voice0: step 0-7
      voice1: step 8-15
      voice2: step 16-23
      step 24-31: 空闲

    控制字格式 (8-bit):
      bit 7:   adder_clk    (1=锁存加法结果)
      bit 6:   out_latch     (1=查表步, 混音锁存)
      bit 5:   param_oe_n    (0=读 7134 参数)
      bit 4:   ram_oe_n      (0=读 62256 phase)
      bit 3:   rom_oe_n      (0=读波表 ROM)
      bit 2:   adder_clr_n   (0=清零加法器)
      bit 1:   reserved
      bit 0:   reserved

    硬件推导:
      voice_sel  = step[4:3]
      param_addr = step[2:0]
    """
    rom = bytearray(524288)

    # 8 种 step[2:0] 只需要 4 种控制字
    CTRL = {
        0: 0x88,  # adder_clk=1, param_oe_n=0, ram_oe_n=0, rom_oe_n=1, adder_clr_n=0
        1: 0x94,  # adder_clk=1, param_oe_n=0, ram_oe_n=0, rom_oe_n=1, adder_clr_n=1
        2: 0x94,  # nib2
        3: 0x94,  # nib3
        4: 0x94,  # nib4
        5: 0x1C,  # param_oe_n=0, ram_oe_n=1, rom_oe_n=1 (vol/wave read)
        6: 0x1C,  # param_oe_n=0, ram_oe_n=1, rom_oe_n=1
        7: 0x74,  # out_latch=1, param_oe_n=1, ram_oe_n=1, rom_oe_n=0 (lookup)
    }
    NOP = 0x3C  # adder_clk=0, out_latch=0, param_oe_n=1, ram_oe_n=1, rom_oe_n=1

    for step in range(32):
        if step >= 24:
            rom[step] = NOP
        else:
            rom[step] = CTRL[step & 7]

    print("  step | Hex | Voice | PA | add | out | poe | rae | roe | clr | Desc")
    print("  -----|-----|-------|----|-----|------|-----|-----|-----|-----|--------")
    for step in range(32):
        val = rom[step]
        voice = (step >> 3) & 3
        pa = step & 7
        if step >= 24:
            desc = "NOP"
        else:
            clk = (val >> 7) & 1
            out = (val >> 6) & 1
            poe = (val >> 5) & 1
            rae = (val >> 4) & 1
            roe = (val >> 3) & 1
            clr = (val >> 2) & 1
            if out:
                desc = "lookup"
            elif pa == 6:
                desc = "vol_read"
            elif pa == 5:
                desc = "wave_read"
            elif not clr:
                desc = f"clr+nib{pa}"
            else:
                desc = f"nib{pa}"
            print(f"  {step:4d} | 0x{val:02X} | v{voice}     | {pa}  |  {clk}   |  {out}   |  {poe}  |  {rae}  |  {roe}  |  {clr}  | {desc}")
        if step >= 24:
            print(f"  {step:4d} | 0x{val:02X} | --     | -- |  -   |  -   |  -   |  -   |  -   |  -   | {desc}")

    return rom

# ============================================================
# 生成波表 ROM (wave × vol 全查表)
# ============================================================
def gen_wavetable_rom():
    """
    RTL: rom_addr = {wave[2:0], vol[3:0], phase[19:12]} = 15-bit
    地址 = wave_idx × 4096 + vol × 256 + phase[19:12]
    值 = wave[phase[19:12] % N] × vol, 8-bit 无符号 (0-225)

    共 8 × 16 × 256 = 32768 字节 (32KB)
    """
    rom = bytearray(524288)

    print("  Wave | Name     | addr base | Range")
    print("  -----|----------|-----------|------")

    for wave_idx in range(8):
        samples = WAVES[wave_idx](N)
        base = wave_idx * 4096  # 16 vols × 256 samples = 4096

        for vol in range(16):
            for idx in range(256):
                val = samples[idx % N] * vol
                addr = base + vol * 256 + idx
                rom[addr] = val & 0xFF

        print(f"  {wave_idx:4d} | {WAVE_NAMES[wave_idx]:8s} | 0x{base:05X}  | [{min(samples)}, {max(samples)}]")

    return rom

# ============================================================
# 主程序
# ============================================================
if __name__ == "__main__":
    print("=== Generating 39SF040 ROM files ===\n")

    # 频率表
    print("--- Frequency Table ---")
    print(f"  Sample rate: {SAMPLE_RATE} Hz (3.072MHz / 32)")
    for name, freq in NOTE_FREQS.items():
        step = freq_to_step(freq)
        print(f"  {name} ({freq:.1f} Hz) → step = {step} (0x{step:05X})")

    # 音域
    min_freq = SAMPLE_RATE / (32 * (1 << 19))
    max_freq = SAMPLE_RATE * ((1 << 20) - 1) / (32 * (1 << 19))
    print(f"\n  音域: {min_freq:.2f} Hz - {max_freq:.0f} Hz")

    # 指令 ROM
    print("\n--- Instruction ROM (rom_instruction.hex) ---")
    print("  32-step microprogram, 8-bit control word, 3 channels × 8 steps + 8 NOP")
    inst_rom = gen_instruction_rom()
    with open("rom/rom_instruction.hex", "w") as f:
        for b in inst_rom:
            f.write(f"{b:02X}\n")
    print(f"  Written: {len(inst_rom)} bytes")

    # 波表 ROM
    print("\n--- Wavetable ROM (rom_wavetable.hex) ---")
    wave_rom = gen_wavetable_rom()
    with open("rom/rom_wavetable.hex", "w") as f:
        for b in wave_rom:
            f.write(f"{b:02X}\n")
    print(f"  Written: {len(wave_rom)} bytes")
    print(f"  LUT size: 32768 bytes (32KB) out of 512KB")

    # 更新主 ROM
    print("\n--- Updating wt_39sf040.hex ---")
    with open("rom/wt_39sf040.hex", "w") as f:
        for b in wave_rom:
            f.write(f"{b:02X}\n")
    print(f"  Written: {len(wave_rom)} bytes")

    print("\nDone.")
