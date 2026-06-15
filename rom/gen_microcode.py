#!/usr/bin/env python3
# gen_microcode.py — 微码 ROM 生成器 (wt3 架构, 3-通道)
#
# 架构:
#   2 片 39SF040 微码 ROM (低字节 + 高字节), 输出 16-bit 控制字段
#   step 计数器 5-bit (step[4:0]), 32 步循环
#   双 62256 (RAM#1=phase_acc, RAM#2=phase_step+wave_idx/vol)
#   3 通道 × 16-bit phase_acc + 16-bit phase_step + wave_idx + vol
#
# 微指令字段 (16 bit):
#   bit 15: p1_oe_n      (62256 #1 OE, 0=read)
#   bit 14: p2_oe_n      (62256 #2 OE, 0=read)
#   bit 13: p1_we_n      (62256 #1 WE, 0=write)
#   bit 12: p2_we_n      (62256 #2 WE, 0=write)
#   bit 11: rom_oe_n    (wavetable ROM OE, 0=read)
#   bit 10: latch_273_n  (DAC output latch, 0=latch)
#   bit  9: latch_carry (74 carry FF, 1=latch C4)
#   bit  8: c0_force0   (1=force 283 C0=0)
#   bit 7-0: ram_addr[7:0]
#
# RAM 地址布局:
#   RAM#1 (p1): phase_acc 存储
#     addr 0-1:   voice 0 phase_acc[15:0]
#     addr 5-6:   voice 1 phase_acc[15:0]
#     addr 10-11: voice 2 phase_acc[15:0]
#   RAM#2 (p2): phase_step + wave_idx/vol
#     addr 2-3:   voice 0 phase_step[15:0]
#     addr 4:     voice 0 wave_idx[1:0] + vol[3:0]
#     addr 7-8:   voice 1 phase_step[15:0]
#     addr 9:     voice 1 wave_idx[1:0] + vol[3:0]
#     addr 12-13: voice 2 phase_step[15:0]
#     addr 14:    voice 2 wave_idx[1:0] + vol[3:0]

NUM_VOICES = 3
PHASE_BITS = 16

VOICE_RAM = {
    0: {"pa_lo": 0x00, "pa_hi": 0x01, "ps_lo": 0x02, "ps_hi": 0x03, "wv": 0x04},
    1: {"pa_lo": 0x05, "pa_hi": 0x06, "ps_lo": 0x07, "ps_hi": 0x08, "wv": 0x09},
    2: {"pa_lo": 0x0A, "pa_hi": 0x0B, "ps_lo": 0x0C, "ps_hi": 0x0D, "wv": 0x0E},
}

F_P1_OE_N     = 1 << 15
F_P2_OE_N     = 1 << 14
F_P1_WE_N     = 1 << 13
F_P2_WE_N     = 1 << 12
F_ROM_OE_N    = 1 << 11
F_LATCH_273_N = 1 << 10
F_LATCH_CARRY = 1 << 9
F_C0_FORCE0   = 1 << 8

NOP_BASE = (F_P1_OE_N | F_P2_OE_N | F_P1_WE_N | F_P2_WE_N |
            F_ROM_OE_N | F_LATCH_273_N)


def mc(ram_addr, p1_oe=0, p2_oe=0, p1_we=0, p2_we=0,
       rom_oe=0, latch_dac=0, latch_carry=0, c0_force0=0):
    val = NOP_BASE | (ram_addr & 0xFF)
    if p1_oe:       val &= ~F_P1_OE_N
    if p2_oe:       val &= ~F_P2_OE_N
    if p1_we:       val &= ~F_P1_WE_N
    if p2_we:       val &= ~F_P2_WE_N
    if rom_oe:      val &= ~F_ROM_OE_N
    if latch_dac:   val &= ~F_LATCH_273_N
    if latch_carry: val |= F_LATCH_CARRY
    if c0_force0:   val |= F_C0_FORCE0
    return val


def step_microcode(step):
    """Return 16-bit microinstruction for step index (0-31).

    3 voices x 8 steps = 24 steps, steps 24-31 = NOP.
    Each voice:
      sub 0: read phase_acc[7:0]  from RAM#1
      sub 1: read phase_step[7:0] from RAM#2
      sub 2: write phase_acc[7:0] to RAM#1 (adder result)
      sub 3: read phase_acc[15:8] from RAM#1, latch carry
      sub 4: read phase_step[15:8] from RAM#2
      sub 5: write phase_acc[15:8] to RAM#1
      sub 6: read wave_idx+vol from RAM#2
      sub 7: read wavetable ROM, latch DAC
    """
    v = step // 8
    s = step % 8
    if v >= NUM_VOICES:
        return NOP_BASE

    r = VOICE_RAM[v]
    if s == 0: return mc(r["pa_lo"], p1_oe=1, c0_force0=1)
    if s == 1: return mc(r["ps_lo"], p2_oe=1, c0_force0=1)
    if s == 2: return mc(r["pa_lo"], p1_we=1, c0_force0=1, latch_carry=1)
    if s == 3: return mc(r["pa_hi"], p1_oe=1)
    if s == 4: return mc(r["ps_hi"], p2_oe=1)
    if s == 5: return mc(r["pa_hi"], p1_we=1)
    if s == 6: return mc(r["wv"],    p2_oe=1)
    if s == 7: return mc(0x00,       rom_oe=1, latch_dac=1)
    return NOP_BASE


def decode_fields(u):
    fields = []
    if not (u & F_P1_OE_N):  fields.append("p1_rd")
    if not (u & F_P2_OE_N):  fields.append("p2_rd")
    if not (u & F_P1_WE_N):  fields.append("p1_wr")
    if not (u & F_P2_WE_N):  fields.append("p2_wr")
    if not (u & F_ROM_OE_N): fields.append("rom_rd")
    if not (u & F_LATCH_273_N): fields.append("dac")
    if u & F_LATCH_CARRY:    fields.append("carry")
    if u & F_C0_FORCE0:      fields.append("c0=0")
    return fields


def main():
    rom_lo = bytearray(524288)
    rom_hi = bytearray(524288)

    for step in range(32):
        ucode = step_microcode(step)
        rom_lo[step] = ucode & 0xFF
        rom_hi[step] = (ucode >> 8) & 0xFF

    nop = step_microcode(24)
    for i in range(32, 524288):
        rom_lo[i] = nop & 0xFF
        rom_hi[i] = (nop >> 8) & 0xFF

    with open("rom/wt3_microcode_lo.hex", "w") as f:
        for b in rom_lo:
            f.write(f"{b:02X}\n")
    with open("rom/wt3_microcode_hi.hex", "w") as f:
        for b in rom_hi:
            f.write(f"{b:02X}\n")

    print(f"Written wt3_microcode_lo.hex ({len(rom_lo)} bytes)")
    print(f"Written wt3_microcode_hi.hex ({len(rom_hi)} bytes)")
    print()
    print(f"{'Step':<5} {'Voice':<7} {'ram':<6} {'hex':<8} fields")
    for step in range(32):
        u = step_microcode(step)
        v = step // 8
        s = step % 8
        voice_str = f"v{v}.s{s}" if v < NUM_VOICES else "-"
        fields = decode_fields(u)
        desc = " ".join(fields) if fields else "NOP"
        print(f"{step:<5} {voice_str:<7} 0x{u & 0xFF:02X}    0x{u:04X}    {desc}")
    print()
    print(f"NOP value: 0x{nop:04X}")
    print(f"Steps 24-31: NOP")


if __name__ == "__main__":
    main()
