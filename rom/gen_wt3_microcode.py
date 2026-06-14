"""gen_wt3_microcode.py — 生成 wt3 微码 ROM (32 字节)

微码控制字 (8-bit):
    bit 7: ram_oe_n      (0=read RAM)
    bit 6: latch_a_n     (0=latch reg_a)
    bit 5: latch_b_n     (0=latch reg_b)
    bit 4: latch_c_n     (0=latch reg_c, volume)
    bit 3: latch_dac_clk (1=latch dac on posedge)
    bit 2: mc_we_n       (0=write adder back to RAM)
    bit 1-0: ram_addr[1:0]
"""

RAM_OE_N = 7
LATCH_A_N = 6
LATCH_B_N = 5
LATCH_C_N = 4
LATCH_DAC = 3
MC_WE_N = 2

def make_ucode(ram_addr=0, ram_oe_n=1, latch_a_n=1, latch_b_n=1,
               latch_c_n=1, dac_clk=0, mc_we_n=1):
    """所有 _n 信号低有效, 0=激活; dac_clk 高有效, 1=激活脉冲。

    逻辑: 参数=0 时对应 bit=0 (低有效激活)。
    参数=1 时对应 bit=1 (高电平, 不激活)。
    因此直接用参数值作为 bit 值, 而不是反转。
    """
    u = 0
    u |= (ram_oe_n & 1) << RAM_OE_N
    u |= (latch_a_n & 1) << LATCH_A_N
    u |= (latch_b_n & 1) << LATCH_B_N
    u |= (latch_c_n & 1) << LATCH_C_N
    u |= (dac_clk & 1) << LATCH_DAC
    u |= (mc_we_n & 1) << MC_WE_N
    u |= ram_addr & 0x03
    return u

NOP = make_ucode()

STEPS = [
    # step 0: 读 RAM[0] = phase_acc
    make_ucode(ram_addr=0, ram_oe_n=0),
    # step 1: latch_a_n=0, 读 RAM[0]
    make_ucode(ram_addr=0, ram_oe_n=0, latch_a_n=0),
    # step 2: 读 RAM[1] = phase_step
    make_ucode(ram_addr=1, ram_oe_n=0),
    # step 3: latch_b_n=0, 读 RAM[1]
    make_ucode(ram_addr=1, ram_oe_n=0, latch_b_n=0),
    # step 4: 读 RAM[2] = volume
    make_ucode(ram_addr=2, ram_oe_n=0),
    # step 5: latch_c_n=0, 读 RAM[2]
    make_ucode(ram_addr=2, ram_oe_n=0, latch_c_n=0),
    # step 6: mc_we_n=0, 写回加法结果到 RAM[0]
    make_ucode(ram_addr=0, mc_we_n=0),
    # step 7: dac_clk 上升沿, 锁存 wavetable ROM 输出
    make_ucode(dac_clk=1),
]

STEPS += [NOP] * (32 - len(STEPS))

def main():
    out_path = "rom/wt3_microcode.hex"
    with open(out_path, "w") as f:
        for u in STEPS:
            f.write(f"{u:02X}\n")
    print(f"Generated {out_path}: 32 bytes")
    for i, u in enumerate(STEPS):
        note = ""
        if i == 0: note = "OE=0, addr=0 (read phase_acc)"
        elif i == 1: note = "latch_a=0, OE=0, addr=0"
        elif i == 2: note = "OE=0, addr=1 (read phase_step)"
        elif i == 3: note = "latch_b=0, OE=0, addr=1"
        elif i == 4: note = "OE=0, addr=2 (read volume)"
        elif i == 5: note = "latch_c=0, OE=0, addr=2"
        elif i == 6: note = "mc_we_n=0, addr=0 (write back phase_acc)"
        elif i == 7: note = "dac_clk pulse (latch wavetable output)"
        else: note = "NOP"
        print(f"  step {i:2d}: 0x{u:02X} - {note}")

if __name__ == "__main__":
    main()
