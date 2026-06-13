#!/usr/bin/env python3
# gen_rom.py — 生成 74HC-Chiptune 的两片 39SF040 ROM
#
# 架构:
#   3 通道, 20-bit phase, 无硬件包络
#   波表 ROM: wave_idx × vol × phase 一次查表, 零运算
#
# ROM1 (指令 ROM): 32 步微程序控制信号
#   3 通道 × 8 步 = 24 步 + 8 空闲 = 32 步循环
#   48kHz = 1.536MHz / 32
#
# ROM2 (波表 ROM): wave × vol 预计算查找表
#   地址 = wave_idx[2:0] × 512 + vol[3:0] × 32 + phase[19:15]
#   共 8 × 16 × 32 = 4096 字节 (4KB)
#   值 = wave[sample] × vol, 范围 0-225 (8-bit 无符号)

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
SAMPLE_RATE = 48000

def freq_to_step(freq):
    return round(freq * (1 << 19) / SAMPLE_RATE)

NOTE_FREQS = {
    'C4': 261.63, 'D4': 293.66, 'E4': 329.63, 'F4': 349.23,
    'G4': 392.00, 'A4': 440.00, 'B4': 493.88, 'C5': 523.25,
}

# ============================================================
# 生成指令 ROM (32 步, 3 通道, 全部 20-bit)
# ============================================================
def gen_instruction_rom():
    """
    32 步循环 (5-bit hc161 × 2 = 0-31)
    48kHz = 1.536MHz / 32

    每通道 8 步:
      0: 清零加法器 + 累加 nib0
      1-4: 累加 nib1-4
      5: 读 vol (7134 addr voice×8+6)
      6: 读 wave (7134 addr voice×8+5)
      7: ROM 查表 + 混音锁存

    通道分配:
      voice0: step 0-7
      voice1: step 8-15
      voice2: step 16-23
      step 24-31: 空闲

    控制字格式 (16-bit):
      bit[15]:    adder_clk    (1=上升沿锁存加法结果到 174)
      bit[14]:    ram_we_n     (0=写 phase nibble 回 62256)
      bit[13]:    adder_clr_n  (0=清零加法器, 每通道第一步)
      bit[12]:    out_latch    (1=查表步, 锁存 ROM 输出到混音)
      bit[11]:    param_oe_n   (0=读 7134 参数)
      bit[10]:    ram_oe_n     (0=读 62256 phase)
      bit[ 9]:    rom_oe_n     (0=读波表 ROM)
      bit[ 8]:    -            (保留)
      bit[7:4]:    param_addr   (7134 子地址: 0-4=freq nib, 5=wave, 6=vol)
      bit[3:0]:    voice_sel   (当前通道 0/1/2)
    """
    rom = bytearray(524288)

    def write_step(ustep, val16):
        addr = ustep * 2
        rom[addr] = val16 & 0xFF
        rom[addr + 1] = (val16 >> 8) & 0xFF

    def make_accum_step(voice, nib, clr=False):
        val = 0
        val |= 1 << 15          # adder_clk
        val |= 0 << 14          # ram_we_n=0 (写回)
        val |= (0 if clr else 1) << 13  # adder_clr_n
        val |= 0 << 12          # out_latch=0
        val |= 0 << 11          # param_oe_n=0 (读 freq nib)
        val |= 0 << 10          # ram_oe_n=0 (读 phase)
        val |= 1 << 9           # rom_oe_n=1 (不读 ROM)
        val |= (nib & 0xF) << 4 # param_addr = nib (freq nibble index)
        val |= (voice & 0xF)    # voice_sel
        return val

    def make_vol_step(voice):
        val = 0
        val |= 0 << 15          # adder_clk=0
        val |= 1 << 14          # ram_we_n=1 (不写)
        val |= 1 << 13          # adder_clr_n=1
        val |= 0 << 12          # out_latch=0
        val |= 0 << 11          # param_oe_n=0 (读 vol)
        val |= 1 << 10          # ram_oe_n=1 (不读 phase)
        val |= 1 << 9           # rom_oe_n=1
        val |= 6 << 4           # param_addr=6 (vol)
        val |= (voice & 0xF)
        return val

    def make_wave_step(voice):
        val = 0
        val |= 0 << 15          # adder_clk=0
        val |= 1 << 14          # ram_we_n=1 (不写)
        val |= 1 << 13          # adder_clr_n=1
        val |= 0 << 12          # out_latch=0
        val |= 0 << 11          # param_oe_n=0 (读 wave)
        val |= 1 << 10          # ram_oe_n=1
        val |= 1 << 9           # rom_oe_n=1
        val |= 5 << 4           # param_addr=5 (wave)
        val |= (voice & 0xF)
        return val

    def make_lookup_step(voice):
        val = 0
        val |= 0 << 15          # adder_clk=0
        val |= 1 << 14          # ram_we_n=1
        val |= 1 << 13          # adder_clr_n=1
        val |= 1 << 12          # out_latch=1
        val |= 1 << 11          # param_oe_n=1 (不读 7134)
        val |= 1 << 10          # ram_oe_n=1
        val |= 0 << 9           # rom_oe_n=0 (读 ROM)
        val |= 0 << 4           # param_addr=0 (unused)
        val |= (voice & 0xF)
        return val

    # voice 0 (step 0-7): 5 累加 + vol + wave + lookup
    write_step(0,  make_accum_step(0, 0, clr=True))
    write_step(1,  make_accum_step(0, 1))
    write_step(2,  make_accum_step(0, 2))
    write_step(3,  make_accum_step(0, 3))
    write_step(4,  make_accum_step(0, 4))
    write_step(5,  make_vol_step(0))
    write_step(6,  make_wave_step(0))
    write_step(7,  make_lookup_step(0))

    # voice 1 (step 8-15)
    write_step(8,  make_accum_step(1, 0, clr=True))
    write_step(9,  make_accum_step(1, 1))
    write_step(10, make_accum_step(1, 2))
    write_step(11, make_accum_step(1, 3))
    write_step(12, make_accum_step(1, 4))
    write_step(13, make_vol_step(1))
    write_step(14, make_wave_step(1))
    write_step(15, make_lookup_step(1))

    # voice 2 (step 16-23)
    write_step(16, make_accum_step(2, 0, clr=True))
    write_step(17, make_accum_step(2, 1))
    write_step(18, make_accum_step(2, 2))
    write_step(19, make_accum_step(2, 3))
    write_step(20, make_accum_step(2, 4))
    write_step(21, make_vol_step(2))
    write_step(22, make_wave_step(2))
    write_step(23, make_lookup_step(2))

    # step 24-31: 空闲 (NOP)
    # adder_clk=0, ram_we_n=1, clr_n=1, out_latch=0, param_oe_n=1, ram_oe_n=1, rom_oe_n=1
    for i in range(24, 32):
        write_step(i, 0x6FFF)  # adder_clk=0, 其他高位=1

    print("  step | Microcode | Voice | PA  | Desc")
    print("  -----|------------|-------|-----|-----")
    for step in range(32):
        addr = step * 2
        val = rom[addr] | (rom[addr + 1] << 8)
        voice = val & 0xF
        pa = (val >> 4) & 0xF
        clk = (val >> 15) & 1
        clr_n = (val >> 13) & 1
        out = (val >> 12) & 1
        param_oe = (val >> 11) & 1
        if val == 0xFFFF or val == 0x6FFF:
            desc = "NOP"
        elif out:
            desc = "lookup"
        elif pa == 6:
            desc = "vol_read"
        elif pa == 5:
            desc = "wave_read"
        elif not clr_n:
            desc = f"clr+nib{pa}"
        elif clk:
            desc = f"nib{pa}"
        else:
            desc = "???"
        print(f"  {step:4d} | 0x{val:04X}     | v{voice}    | {pa}   | {desc}")

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
    print(f"  Sample rate: {SAMPLE_RATE} Hz (1.536MHz / 32)")
    for name, freq in NOTE_FREQS.items():
        step = freq_to_step(freq)
        print(f"  {name} ({freq:.1f} Hz) → step = {step} (0x{step:05X})")

    # 音域
    min_freq = SAMPLE_RATE / (32 * (1 << 19))
    max_freq = SAMPLE_RATE * ((1 << 20) - 1) / (32 * (1 << 19))
    print(f"\n  音域: {min_freq:.2f} Hz - {max_freq:.0f} Hz")

    # 指令 ROM
    print("\n--- Instruction ROM (rom_instruction.hex) ---")
    print("  32-step microprogram, 3 channels × 8 steps + 8 NOP")
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
