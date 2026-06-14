"""gen_wt3_microcode.py — 生成 wt3 微码 ROM (64 字节, v1.4: 16-bit phase)

每通道 16 step = 13 工作 + 3 NOP
4 通道 × 16 step = 64 step 完整循环

微码控制字 (8-bit, v1.4):
    bit 7: ram_oe_n      (0=read RAM)
    bit 6: ram_we_n      (0=write RAM)
    bit 5-3: reserved
    bit 2-0: ram_sub_addr (3-bit: 0=acc_lo, 1=acc_hi, 2=step_lo, 3=step_hi, 4=vol)

latch/dac_clk 由 154 硬译码 step[3:0] 提供,不占微码位。
"""

RAM_OE_N = 7
RAM_WE_N = 6

# 通道内 RAM 子地址 (3-bit)
ADDR_ACC_LO = 0
ADDR_ACC_HI = 1
ADDR_STEP_LO = 2
ADDR_STEP_HI = 3
ADDR_VOLUME = 4

NUM_CHANNELS = 4
STEPS_PER_CHANNEL = 16  # 13 工作 + 3 NOP
ROM_SIZE = 64  # 2^6


def make_ucode(ram_sub_addr=0, ram_oe_n=1, ram_we_n=1):
    u = 0
    u |= (ram_oe_n & 1) << RAM_OE_N
    u |= (ram_we_n & 1) << RAM_WE_N
    u |= ram_sub_addr & 0x07
    return u


NOP = make_ucode()


# 每通道 16 step 微码
# step 0-9:  读操作 + 锁存 (latch 由 154 硬译码)
# step 10-11: 写回 adder 结果 (lo/hi 分两次)
# step 12: dac_clk (由 154 硬译码, Y12 反相)
# step 13-15: NOP
def make_channel_steps():
    return [
        # step 0: 读 acc_lo, latch 由 154 Y1 在 step 1 触发
        make_ucode(ram_sub_addr=ADDR_ACC_LO, ram_oe_n=0),
        # step 1: 仍在读 acc_lo (OE 保持), latch_a_lo 由 154 Y1 触发
        make_ucode(ram_sub_addr=ADDR_ACC_LO, ram_oe_n=0),
        # step 2: 读 acc_hi
        make_ucode(ram_sub_addr=ADDR_ACC_HI, ram_oe_n=0),
        # step 3: latch_a_hi 由 154 Y3 触发
        make_ucode(ram_sub_addr=ADDR_ACC_HI, ram_oe_n=0),
        # step 4: 读 step_lo
        make_ucode(ram_sub_addr=ADDR_STEP_LO, ram_oe_n=0),
        # step 5: latch_b_lo 由 154 Y5 触发
        make_ucode(ram_sub_addr=ADDR_STEP_LO, ram_oe_n=0),
        # step 6: 读 step_hi
        make_ucode(ram_sub_addr=ADDR_STEP_HI, ram_oe_n=0),
        # step 7: latch_b_hi 由 154 Y7 触发
        make_ucode(ram_sub_addr=ADDR_STEP_HI, ram_oe_n=0),
        # step 8: 读 volume
        make_ucode(ram_sub_addr=ADDR_VOLUME, ram_oe_n=0),
        # step 9: latch_c 由 154 Y9 触发
        make_ucode(ram_sub_addr=ADDR_VOLUME, ram_oe_n=0),
        # step 10: 写回 acc_lo (WE=0, DI = adder_lo, step[0]=0 选择)
        make_ucode(ram_sub_addr=ADDR_ACC_LO, ram_we_n=0),
        # step 11: NOP (WE=1, 让 we_n 产生上升沿, 为 step 12 准备)
        make_ucode(),
        # step 12: 写回 acc_hi (WE=0, DI = adder_hi, step[0]=0 选择)
        # 注意: step[0]=0 但 sub_addr=1, mux 应基于 sub_addr 而非 step[0]
        make_ucode(ram_sub_addr=ADDR_ACC_HI, ram_we_n=0),
        # step 13: dac_clk 由 154 Y13 反相触发
        make_ucode(),  # OE=1, WE=1, NOP (但 154 硬译码处理 dac)
        # step 14-15: NOP
        make_ucode(),
        make_ucode(),
    ]


def main():
    STEPS = []
    for ch in range(NUM_CHANNELS):
        STEPS.extend(make_channel_steps())

    assert len(STEPS) == ROM_SIZE

    out_path = "rom/wt3_microcode.hex"
    with open(out_path, "w") as f:
        for u in STEPS:
            f.write(f"{u:02X}\n")
    print(f"Generated {out_path}: {ROM_SIZE} bytes ({NUM_CHANNELS} channels x {STEPS_PER_CHANNEL} steps)")
    print()
    for i, u in enumerate(STEPS):
        ch = i // STEPS_PER_CHANNEL
        sub = i % STEPS_PER_CHANNEL
        if sub < 13:
            notes = {
                0: f"OE=0 addr=acc_lo",
                1: f"OE=0 addr=acc_lo [latch_a_lo @Y1]",
                2: f"OE=0 addr=acc_hi",
                3: f"OE=0 addr=acc_hi [latch_a_hi @Y3]",
                4: f"OE=0 addr=step_lo",
                5: f"OE=0 addr=step_lo [latch_b_lo @Y5]",
                6: f"OE=0 addr=step_hi",
                7: f"OE=0 addr=step_hi [latch_b_hi @Y7]",
                8: f"OE=0 addr=vol",
                9: f"OE=0 addr=vol [latch_c @Y9]",
                10: f"WE=0 addr=acc_lo [writeback_lo]",
                11: f"WE=0 addr=acc_hi [writeback_hi]",
                12: f"[dac_clk @Y12]",
            }
            note = notes.get(sub, "?")
            print(f"  step {i:2d} (ch{ch}.{sub:2d}): 0x{u:02X} - {note}")
        else:
            print(f"  step {i:2d} (ch{ch}.{sub:2d}): 0x{u:02X} - NOP")


if __name__ == "__main__":
    main()
