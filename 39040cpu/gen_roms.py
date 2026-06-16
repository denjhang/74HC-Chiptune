#!/usr/bin/env python3
"""gen_roms.py — 39040cpu ROM 生成器
生成 3 片 ROM 的 hex 文件:
  ctrl.hex  — 控制字 (INS|MOD|BUS)
  data.hex  — 立即数 D
  alu.hex   — ALU 查表 ({INS, AC, bus} → result)
"""

import os

ROM_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rom39040")

def write_hex(filename, data, depth=524288):
    """写入 hex 文件 (空格分隔, 小写, 每行 16 字节)"""
    path = os.path.join(ROM_DIR, filename)
    with open(path, "w", newline="\n") as f:
        for i in range(0, depth, 16):
            chunk = data[i:i+16]
            f.write(" ".join(f"{b:02x}" for b in chunk) + "\n")
    print(f"  {path}: {depth} bytes")

def gen_alu_rom():
    """ALU 查表: 512K = 8 种 INS × 64K (AC, bus) 组合
    地址: {INS[2:0], AC[7:0], bus[7:0]} = {A18:A16, A15:A8, A7:A0}
    """
    alu = bytearray(524288)

    for ins in range(8):
        base = ins * 65536  # 每个 INS 占 64K
        for ac in range(256):
            for bus in range(256):
                addr = base + (ac << 8) + bus
                if ins == 0:    # LD:   result = bus
                    alu[addr] = bus & 0xFF
                elif ins == 1:  # AND:  result = AC & bus
                    alu[addr] = (ac & bus) & 0xFF
                elif ins == 2:  # OR:   result = AC | bus
                    alu[addr] = (ac | bus) & 0xFF
                elif ins == 3:  # XOR:  result = AC ^ bus
                    alu[addr] = (ac ^ bus) & 0xFF
                elif ins == 4:  # ADD:  result = AC + bus (8-bit)
                    alu[addr] = (ac + bus) & 0xFF
                elif ins == 5:  # SUB:  result = AC - bus (8-bit)
                    alu[addr] = (ac - bus) & 0xFF
                elif ins == 6:  # ST:   result = bus (写 RAM)
                    alu[addr] = bus & 0xFF
                elif ins == 7:  # JMP:  result = bus (跳转地址低字节)
                    alu[addr] = bus & 0xFF

    return alu

def gen_test_program():
    """生成测试程序: ALU + RAM + JMP + 条件分支 + 循环

    测试目标 (OUT 输出序列):
      ALU 测试:
        1. LD OUT, 0x42       → OUT = 0x42
        2. ADD 0x13+0x37       → OUT = 0x4A
        3. AND 0xFF&0x0F       → OUT = 0x0F
        4. OR  0xA5|0x3C       → OUT = 0xBD
        5. XOR 0xFF^0xAA       → OUT = 0x55
        6. SUB 0x50-0x20       → OUT = 0x30
      RAM 读写测试:
        7. ST [0x10], 0xDE    → 写 RAM[0x10] = 0xDE
        8. LD AC, [0x10]       → 读 RAM[0x10] = 0xDE
        9. LD OUT, AC          → OUT = 0xDE
      条件分支测试:
       10. LD AC, 0x80        → AC = 0x80 (negative)
       11. BN skip            → AC[7]=1, branch taken → skip next
       12. LD OUT, 0xAA       → (skipped)
       13. LD OUT, 0xBB       → OUT = 0xBB (证明跳过了 0xAA)
      循环测试 (count down 3→0, output 0x03, 0x02, 0x01):
       14. LD X, 0x03         → X = 3
       15. LD Y, loop_start   → Y = 循环起始地址
       16. loop: LD AC, X      → AC = X
       17. LD OUT, AC         → output X
       18. SUB AC, 0x01       → AC = X - 1
       19. BZ end              → if X-1 == 0, branch to end
       20. LD X, AC            → X = X - 1
       21. JMP [Y]             → jump back to loop
       22. end: LD OUT, 0xFF   → OUT = 0xFF (loop done)
       23. JMP self
    """

    def encode(ins, mod, bus):
        return (ins << 5) | (mod << 2) | bus

    # INS
    LD  = 0
    AND = 1
    OR  = 2
    XOR = 3
    ADD = 4
    SUB = 5
    ST  = 6
    JMP = 7

    # MOD (非JMP)
    MODE_D   = 0  # [D]
    MODE_X   = 1  # [X]
    MODE_Y   = 2  # [Y]
    MODE_YX  = 3  # [Y+X]
    TO_X     = 4  # → X
    TO_Y     = 5  # → Y
    TO_OUT   = 6  # → OUT
    MODE_YX_INC = 7  # [Y+X], X++

    # MOD (JMP)
    JMP_FAR = 0  # 无条件远跳 {Y, bus}
    B_CARRY = 1  # carry
    B_ZERO  = 2  # zero
    B_NEG   = 4  # negative

    # BUS
    BUS_D   = 0
    BUS_RAM = 1
    BUS_AC  = 2
    BUS_IN  = 3
    BUS_X   = BUS_D   # X 间接寻址: MOD=1(MODE_X), bus 选择 X 地址

    prog = []

    # === ALU 测试 ===
    # [0] LD AC, 0x42
    prog.append((encode(LD, MODE_D, BUS_D), 0x42))
    # [1] LD OUT, AC
    prog.append((encode(LD, TO_OUT, BUS_AC), 0x00))
    # [2] LD AC, 0x13
    prog.append((encode(LD, MODE_D, BUS_D), 0x13))
    # [3] ADD AC, 0x37 → 0x4A
    prog.append((encode(ADD, MODE_D, BUS_D), 0x37))
    # [4] LD OUT, AC
    prog.append((encode(LD, TO_OUT, BUS_AC), 0x00))
    # [5] LD AC, 0xFF
    prog.append((encode(LD, MODE_D, BUS_D), 0xFF))
    # [6] AND AC, 0x0F → 0x0F
    prog.append((encode(AND, MODE_D, BUS_D), 0x0F))
    # [7] LD OUT, AC
    prog.append((encode(LD, TO_OUT, BUS_AC), 0x00))
    # [8] LD AC, 0xA5
    prog.append((encode(LD, MODE_D, BUS_D), 0xA5))
    # [9] OR AC, 0x3C → 0xBD
    prog.append((encode(OR, MODE_D, BUS_D), 0x3C))
    # [10] LD OUT, AC
    prog.append((encode(LD, TO_OUT, BUS_AC), 0x00))
    # [11] LD AC, 0xFF
    prog.append((encode(LD, MODE_D, BUS_D), 0xFF))
    # [12] XOR AC, 0xAA → 0x55
    prog.append((encode(XOR, MODE_D, BUS_D), 0xAA))
    # [13] LD OUT, AC
    prog.append((encode(LD, TO_OUT, BUS_AC), 0x00))
    # [14] LD AC, 0x50
    prog.append((encode(LD, MODE_D, BUS_D), 0x50))
    # [15] SUB AC, 0x20 → 0x30
    prog.append((encode(SUB, MODE_D, BUS_D), 0x20))
    # [16] LD OUT, AC
    prog.append((encode(LD, TO_OUT, BUS_AC), 0x00))

    # === RAM 读写测试 ===
    # [17] LD AC, 0xDE
    prog.append((encode(LD, MODE_D, BUS_D), 0xDE))
    # [18] ST [0x10], AC → RAM[0x10] = 0xDE
    #   ST 用 MOD=0 (addr=D=0x10), bus=D=0x10
    #   但 ST 写入 bus_data 到 mem_addr
    #   mem_addr = {0, D} = 0x10, bus = AC (BUS_AC)
    #   ST 控制字: INS=6, MOD=0([D]=addr_lo), BUS=2(AC)
    prog.append((encode(ST, MODE_D, BUS_AC), 0x10))
    # [19] LD AC, 0x00 (clear AC to prove RAM read)
    prog.append((encode(LD, MODE_D, BUS_D), 0x00))
    # [20] LD AC, [0x10] → read RAM[0x10]
    prog.append((encode(LD, MODE_D, BUS_RAM), 0x10))
    # [21] LD OUT, AC → OUT = 0xDE
    prog.append((encode(LD, TO_OUT, BUS_AC), 0x00))

    # === 条件分支测试 ===
    # [22] LD AC, 0x80 (negative)
    prog.append((encode(LD, MODE_D, BUS_D), 0x80))
    # [23] BN +2 → if AC[7]=1, jump to [25]
    #   JMP with MOD=B_NEG(4), target = pc_hi + D
    prog.append((encode(JMP, B_NEG, BUS_D), 0x19))  # 23+2=25
    # [24] LD OUT, 0xAA (should be SKIPPED)
    prog.append((encode(LD, TO_OUT, BUS_D), 0xAA))
    # [25] LD OUT, 0xBB → should appear
    prog.append((encode(LD, TO_OUT, BUS_D), 0xBB))

    # === 循环测试 (用 AC 做计数器, 倒数 3→1) ===
    # [26] LD AC, 0x03
    prog.append((encode(LD, MODE_D, BUS_D), 0x03))
    # [27] LD Y, 0x00 → Y = 0 (far jump 高字节)
    prog.append((encode(LD, TO_Y, BUS_D), 0x00))
    # loop_start [28]: LD OUT, AC → output counter
    prog.append((encode(LD, TO_OUT, BUS_AC), 0x00))
    # [29]: SUB AC, 0x01 → AC--
    prog.append((encode(SUB, MODE_D, BUS_D), 0x01))
    # [30]: BZ 33 → if AC==0, near jump to instruction 33
    #   d_reg = 33 (instruction index), 硬件: PC = {pc_hi, 33, 1}
    #   rom_addr = {pc_hi, 33} = 33
    prog.append((encode(JMP, B_ZERO, BUS_D), 0x21))
    # [31]: JMP FAR → jump back to instruction 28
    #   target = {Y=0, bus_data[7:1]=28, 1'b1}, rom_addr = {0, 28} = 28
    #   bus_data = 28<<1 | 1 = 57 = 0x39
    prog.append((encode(JMP, JMP_FAR, BUS_D), 0x39))
    # [32]: (padding, never reached)
    prog.append((encode(LD, MODE_D, BUS_D), 0x00))
    # [33]: LD OUT, 0xFF (loop done)
    prog.append((encode(LD, TO_OUT, BUS_D), 0xFF))
    # [34]: JMP self → infinite halt
    #   bus_data = 34<<1 | 1 = 69 = 0x45
    prog.append((encode(JMP, JMP_FAR, BUS_D), 0x45))

    ctrl = bytearray(524288)
    data = bytearray(524288)

    for i, (c, d) in enumerate(prog):
        ctrl[i] = c
        data[i] = d

    return ctrl, data

def main():
    os.makedirs(ROM_DIR, exist_ok=True)

    print("=== 39040cpu ROM Generator ===")

    print("\nGenerating ALU lookup table...")
    alu = gen_alu_rom()
    write_hex("alu.hex", alu)

    print("\nGenerating test program...")
    ctrl, data = gen_test_program()
    write_hex("ctrl.hex", ctrl)
    write_hex("data.hex", data)

    print("\nDone!")

if __name__ == "__main__":
    main()
