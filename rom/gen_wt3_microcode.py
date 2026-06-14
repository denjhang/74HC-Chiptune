"""gen_wt3_microcode.py — 生成 wt3 微码 ROM (64 字节, 4 通道 TDM 版本 v1.3)

每通道 16 step = 8 工作 + 8 NOP
4 通道 × 16 step = 64 step 完整循环

微码控制字 (8-bit):
    bit 7: ram_oe_n      (0=read RAM)
    bit 6: latch_a_n     (0=latch reg_a)
    bit 5: latch_b_n     (0=latch reg_b)
    bit 4: latch_c_n     (0=latch reg_c, volume)
    bit 3: latch_dac_clk (1=latch dac on posedge)
    bit 2: mc_we_n       (0=write adder back to RAM)
    bit 1-0: ram_sub_addr[1:0]  (通道内偏移: 0=phase_acc, 1=phase_step, 2=volume)

通道号 = step[5:4] (取自 step 计数器)
通道内偏移 = step[3:0]

实际 RAM 地址 = (channel << 2) | ram_sub_addr (5-bit)
"""

RAM_OE_N = 7
LATCH_A_N = 6
LATCH_B_N = 5
LATCH_C_N = 4
LATCH_DAC = 3
MC_WE_N = 2

# 通道内 RAM 偏移
ADDR_PHASE_ACC = 0
ADDR_PHASE_STEP = 1
ADDR_VOLUME = 2

NUM_CHANNELS = 4
STEPS_PER_CHANNEL = 16  # 8 工作 + 8 NOP
WORK_STEPS = 8
ROM_SIZE = 64  # 2^6, 4 通道 × 16 step = 64


def make_ucode(ram_sub_addr=0, ram_oe_n=1, latch_a_n=1, latch_b_n=1,
               latch_c_n=1, dac_clk=0, mc_we_n=1):
    """构造 8-bit 微码字。默认所有控制信号 inactive (高有效信号=1, 低有效=0)。"""
    u = 0
    u |= (ram_oe_n & 1) << RAM_OE_N
    u |= (latch_a_n & 1) << LATCH_A_N
    u |= (latch_b_n & 1) << LATCH_B_N
    u |= (latch_c_n & 1) << LATCH_C_N
    u |= (dac_clk & 1) << LATCH_DAC
    u |= (mc_we_n & 1) << MC_WE_N
    u |= ram_sub_addr & 0x03
    return u


# NOP: 所有控制信号 inactive (OE关, 所有latch关, WE关)
NOP = make_ucode()


# 单通道 8 step 工作微码 + 8 step NOP
def make_channel_steps():
    return [
        # step 0: 读 phase_acc
        make_ucode(ram_sub_addr=ADDR_PHASE_ACC, ram_oe_n=0),
        # step 1: latch_a + 读 phase_acc (下 step 切到 phase_step)
        make_ucode(ram_sub_addr=ADDR_PHASE_ACC, ram_oe_n=0, latch_a_n=0),
        # step 2: 读 phase_step
        make_ucode(ram_sub_addr=ADDR_PHASE_STEP, ram_oe_n=0),
        # step 3: latch_b
        make_ucode(ram_sub_addr=ADDR_PHASE_STEP, ram_oe_n=0, latch_b_n=0),
        # step 4: 读 volume
        make_ucode(ram_sub_addr=ADDR_VOLUME, ram_oe_n=0),
        # step 5: latch_c
        make_ucode(ram_sub_addr=ADDR_VOLUME, ram_oe_n=0, latch_c_n=0),
        # step 6: 写回加法结果到 phase_acc
        make_ucode(ram_sub_addr=ADDR_PHASE_ACC, mc_we_n=0),
        # step 7: dac_clk 上升沿, 锁存 wavetable ROM 输出
        make_ucode(dac_clk=1),
    ] + [NOP] * (STEPS_PER_CHANNEL - WORK_STEPS)


def main():
    STEPS = []
    for ch in range(NUM_CHANNELS):
        STEPS.extend(make_channel_steps())

    assert len(STEPS) == ROM_SIZE, f"ROM size mismatch: {len(STEPS)} != {ROM_SIZE}"

    out_path = "rom/wt3_microcode.hex"
    with open(out_path, "w") as f:
        for u in STEPS:
            f.write(f"{u:02X}\n")
    print(f"Generated {out_path}: {ROM_SIZE} bytes "
          f"({NUM_CHANNELS} channels × {STEPS_PER_CHANNEL} steps)")
    print()
    for i, u in enumerate(STEPS):
        ch = i // STEPS_PER_CHANNEL
        sub = i % STEPS_PER_CHANNEL
        if sub < WORK_STEPS:
            note = ""
            if sub == 0: note = f"ch{ch}: OE=0, addr={ADDR_PHASE_ACC} (read phase_acc)"
            elif sub == 1: note = f"ch{ch}: latch_a=0, OE=0, addr={ADDR_PHASE_ACC}"
            elif sub == 2: note = f"ch{ch}: OE=0, addr={ADDR_PHASE_STEP} (read phase_step)"
            elif sub == 3: note = f"ch{ch}: latch_b=0, OE=0, addr={ADDR_PHASE_STEP}"
            elif sub == 4: note = f"ch{ch}: OE=0, addr={ADDR_VOLUME} (read volume)"
            elif sub == 5: note = f"ch{ch}: latch_c=0, OE=0, addr={ADDR_VOLUME}"
            elif sub == 6: note = f"ch{ch}: mc_we_n=0, addr={ADDR_PHASE_ACC} (write back)"
            elif sub == 7: note = f"ch{ch}: dac_clk pulse (latch wavetable)"
            print(f"  step {i:2d} (ch{ch}.{sub:2d}): 0x{u:02X} - {note}")
        else:
            print(f"  step {i:2d} (ch{ch}.{sub:2d}): 0x{u:02X} - NOP (SPFM 写参数窗口)")


if __name__ == "__main__":
    main()
