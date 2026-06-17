#!/usr/bin/env python3
"""gen_roms.py — 生成微指令 ROM (PC 直接寻址, 15 片版含 SRAM)

15 片: 5×161 + 3×39SF040 + 2×377 + 4×157 + 1×62256 (无04!)

uctl 格式 (8-bit, 负逻辑编码, 直连芯片低有效引脚):
  [0]   ac_dis_n  (1=禁止AC锁存, 直连 377 Enable_bar)
  [3:1] alu_op    (000=直通, 001=ADD, 010=SUB)
  [4]   bus_sel   (0=udata, 1=ram_do)
  [5]   ram_we_n  (0=写SRAM, 直连 62256 WE_n)
  [6]   mem_sel   (0=udata做地址, 1=x_reg做地址)
  [7]   to_x_n    (0=锁存x_reg, 直连 377 Enable_bar)

指令编码 (所有非ST指令 bit5=1 即 ram_we_n=1 确保读模式):
  NOP       uctl=0x21  (ac_dis_n=1, ram_we_n=1)
  LD #imm   uctl=0x20  (alu_op=000, bus_sel=0, ram_we_n=1)
  ADD #imm  uctl=0x22  (alu_op=001, bus_sel=0, ram_we_n=1)
  SUB #imm  uctl=0x24  (alu_op=010, bus_sel=0, ram_we_n=1)
  LD [addr] uctl=0x30  (alu_op=000, bus_sel=1, ram_we_n=1)
  ST [addr] uctl=0x01  (ac_dis_n=1, ram_we_n=0, 写SRAM, AC不变)
  ADD [addr] uctl=0x32  (alu_op=001, bus_sel=1, ram_we_n=1)
  SUB [addr] uctl=0x34  (alu_op=010, bus_sel=1, ram_we_n=1)
  LD X      uctl=0x70  (alu_op=000, bus_sel=1, to_x_n=0, ram_we_n=1)
"""

import os

os.makedirs("rom", exist_ok=True)

# ============================================================
# ALU ROM — 512K×8
# 地址: alu_d[7:0] | AC[7:0] | alu_op[2:0]
# ============================================================
ALU_SIZE = 512 * 1024
alu = bytearray(ALU_SIZE)
for addr in range(ALU_SIZE):
    d   = addr & 0xFF
    acc = (addr >> 8) & 0xFF
    op  = (addr >> 16) & 0x07
    if op == 0b001:
        alu[addr] = (acc + d) & 0xFF
    elif op == 0b010:
        alu[addr] = (acc - d) & 0xFF
    else:
        alu[addr] = d

with open("rom/alu.hex", "w", newline="\n") as f:
    for i in range(0, ALU_SIZE, 16):
        chunk = alu[i:i+16]
        f.write(" ".join(f"{b:02x}" for b in chunk) + "\n")
print("Generated rom/alu.hex (512K)")

# ============================================================
# 测试程序: SRAM 读写 + ADD
# ============================================================
uctl = bytearray(256)
udata = bytearray(256)

# PC=0: NOP (ac_dis_n=1, ram_we_n=1)
uctl[0] = 0x21

steps = [
    # (PC, uctl, udata, comment)
    (1, 0x20, 0x01, "LD 0x01"),        # ram_we_n=1, AC<=1
    (2, 0x01, 0x80, "ST [0x80]"),      # ac_dis_n=1, ram_we_n=0, RAM[0x80]<=AC(=1)
    (3, 0x20, 0x05, "LD 0x05"),        # ram_we_n=1, AC<=5
    (4, 0x32, 0x80, "ADD [0x80]"),     # ram_we_n=1, AC<=5+RAM[0x80]=6
    (5, 0x01, 0x81, "ST [0x81]"),      # ac_dis_n=1, ram_we_n=0, RAM[0x81]<=AC(=6)
    (6, 0x30, 0x80, "LD [0x80]"),      # ram_we_n=1, AC<=RAM[0x80]=1
    (7, 0x32, 0x81, "ADD [0x81]"),     # ram_we_n=1, AC<=1+RAM[0x81]=7
    (8, 0x20, 0x03, "LD 0x03"),        # ram_we_n=1, AC<=3
    (9, 0x32, 0x81, "ADD [0x81]"),     # ram_we_n=1, AC<=3+RAM[0x81]=9
]

for addr, c, d, comment in steps:
    uctl[addr] = c
    udata[addr] = d
    print(f"  PC={addr}: uctl=0x{c:02x} udata=0x{d:02x}  ; {comment}")

with open("rom/uctl.hex", "w", newline="\n") as f:
    for i in range(0, 256, 16):
        chunk = uctl[i:i+16]
        f.write(" ".join(f"{b:02x}" for b in chunk) + "\n")
with open("rom/udata.hex", "w", newline="\n") as f:
    for i in range(0, 256, 16):
        chunk = udata[i:i+16]
        f.write(" ".join(f"{b:02x}" for b in chunk) + "\n")

print("\nGenerated rom/uctl.hex, rom/udata.hex")
print("Expected (skip NOP): 01 01 05 06 06 01 07 03 09")
