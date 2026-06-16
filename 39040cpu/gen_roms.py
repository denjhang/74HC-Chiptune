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
    """生成测试程序: 简单的 LD + OUT 序列

    测试目标:
      1. LD AC, 0x42      → AC = 0x42
      2. LD OUT, AC       → OUT = 0x42 (DATA_OUT 应为 0x42)
      3. LD AC, 0x13      → AC = 0x13
      4. ADD AC, 0x37     → AC = 0x4A (0x13 + 0x37)
      5. LD OUT, AC       → OUT = 0x4A
      6. LD AC, 0xFF      → AC = 0xFF
      7. AND AC, 0x0F     → AC = 0x0F
      8. LD OUT, AC       → OUT = 0x0F
      9. LD AC, 0xA5      → AC = 0xA5
     10. OR  AC, 0x3C     → AC = 0xBD
     11. LD OUT, AC       → OUT = 0xBD
     12. LD AC, 0xFF      → AC = 0xFF
     13. XOR AC, 0xAA     → AC = 0x55
     14. LD OUT, AC       → OUT = 0x55
     15. LD AC, 0x50      → AC = 0x50
     16. SUB AC, 0x20     → AC = 0x30
     17. LD OUT, AC       → OUT = 0x30

    指令编码: INS[7:5]|MOD[4:2]|BUS[1:0]
    """

    # 指令助记 → 编码
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

    # MOD
    MODE_D   = 0  # [D]
    MODE_X   = 1  # [X]
    MODE_Y   = 2  # [Y]
    MODE_YX  = 3  # [Y+X]
    TO_X     = 4  # → X
    TO_Y     = 5  # → Y
    TO_OUT   = 6  # → OUT
    MODE_YX_INC = 7  # [Y+X], X++

    # BUS
    BUS_D   = 0  # D (ROM2)
    BUS_RAM = 1  # RAM
    BUS_AC  = 2  # AC
    BUS_IN  = 3  # EXT_IN

    ctrl_prog = []
    data_prog = []

    # 指令列表: (ctrl_byte, data_byte)
    prog = [
        # 1. LD AC, 0x42
        (encode(LD, MODE_D, BUS_D), 0x42),
        # 2. LD OUT, AC (bus=AC, mod=TO_OUT)
        (encode(LD, TO_OUT, BUS_AC), 0x00),
        # 3. LD AC, 0x13
        (encode(LD, MODE_D, BUS_D), 0x13),
        # 4. ADD AC, 0x37
        (encode(ADD, MODE_D, BUS_D), 0x37),
        # 5. LD OUT, AC
        (encode(LD, TO_OUT, BUS_AC), 0x00),
        # 6. LD AC, 0xFF
        (encode(LD, MODE_D, BUS_D), 0xFF),
        # 7. AND AC, 0x0F
        (encode(AND, MODE_D, BUS_D), 0x0F),
        # 8. LD OUT, AC
        (encode(LD, TO_OUT, BUS_AC), 0x00),
        # 9. LD AC, 0xA5
        (encode(LD, MODE_D, BUS_D), 0xA5),
        # 10. OR AC, 0x3C
        (encode(OR, MODE_D, BUS_D), 0x3C),
        # 11. LD OUT, AC
        (encode(LD, TO_OUT, BUS_AC), 0x00),
        # 12. LD AC, 0xFF
        (encode(LD, MODE_D, BUS_D), 0xFF),
        # 13. XOR AC, 0xAA
        (encode(XOR, MODE_D, BUS_D), 0xAA),
        # 14. LD OUT, AC
        (encode(LD, TO_OUT, BUS_AC), 0x00),
        # 15. LD AC, 0x50
        (encode(LD, MODE_D, BUS_D), 0x50),
        # 16. SUB AC, 0x20
        (encode(SUB, MODE_D, BUS_D), 0x20),
        # 17. LD OUT, AC
        (encode(LD, TO_OUT, BUS_AC), 0x00),
    ]

    # 18. JMP self (无限循环)
    (encode(JMP, MODE_D, BUS_D), 0x00),

    # 填充到 512K
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
