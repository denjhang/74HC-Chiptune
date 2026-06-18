#!/usr/bin/env python3
"""gen_roms.py — 生成微指令 ROM (PC 直接寻址, 18 片版含 JMP+OUT)

18 片: 5×161 + 4×39SF040 + 3×377 + 4×157 + 1×62256

uctl_lo (8-bit, 负逻辑编码):
  [0]   ac_dis_n  (1=禁止AC)
  [3:1] alu_op    (000=直通, 001=ADD, 010=SUB)
  [4]   bus_sel   (0=udata, 1=ram_do)
  [5]   ram_we_n  (0=写SRAM)
  [6]   mem_sel   (0=udata地址, 1=x_reg地址)
  [7]   to_x_n    (0=锁存x_reg)

uctl_hi (8-bit, 负逻辑编码):
  [0]   pc_pe_n   (0=JMP, 直连 161 PE)
  [1]   to_y_n    (0=锁存y_reg)
  [2]   to_out_n  (0=锁存out_reg)

指令编码:
  NOP       lo=0x21 hi=0x01  (ac_dis=1, ram_we=1, pc_pe=1)
  LD #imm   lo=0x20 hi=0x01  (ram_we=1)
  ADD #imm  lo=0x22 hi=0x01  (alu_op=001, ram_we=1)
  SUB #imm  lo=0x24 hi=0x01  (alu_op=010, ram_we=1)
  LD [addr] lo=0x30 hi=0x01  (bus_sel=1, ram_we=1)
  ST [addr] lo=0x01 hi=0x01  (ac_dis=1, ram_we=0)
  ADD [addr] lo=0x32 hi=0x01  (alu_op=001, bus_sel=1, ram_we=1)
  OUT       lo=0x21 hi=0x05  (ac_dis=1, to_out=0)
  JMP addr  lo=0x21 hi=0x00  (ac_dis=1, pc_pe=0, addr={y,udata})
  LD Y      lo=0x30 hi=0x03  (bus_sel=1, ram_we=1, to_y=0, 读ram到Y)
"""

import os

os.makedirs("rom", exist_ok=True)

# ALU ROM (不变)
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
# 测试程序: JMP + OUT
#
# PC=0:  LD 0x0A       ; AC=10
# PC=1:  OUT            ; out_reg=10, DATA_OUT=10
# PC=2:  LD 0x01       ; AC=1
# PC=3:  ST [0x80]     ; RAM[0x80]=1
# PC=4:  LD [0x80]     ; AC=RAM[0x80]=1
# PC=5:  ADD 0x01       ; AC=2
# PC=6:  ST [0x80]     ; RAM[0x80]=2
# PC=7:  OUT            ; out_reg=2, DATA_OUT=2
# PC=8:  JMP 0x00       ; 跳到 PC=0 (无限循环)
#
# 有效输出: 10, 02, 02, 02, ...
# ============================================================
uctl_lo = bytearray(256)
uctl_hi = bytearray(256)
udata = bytearray(256)

NOP = (0x21, 0x01)
LD_IMM = (0x20, 0x01)
ADD_IMM = (0x22, 0x01)
ST = (0x01, 0x01)
LD_ADDR = (0x30, 0x01)
ADD_ADDR = (0x32, 0x01)
OUT = (0x21, 0x05)      # ac_dis_n=1, to_out_n=0
JMP = (0x21, 0x00)      # ac_dis_n=1, pc_pe_n=0

steps = [
    # (PC, lo, hi, udata, comment)
    (0, LD_IMM[0], LD_IMM[1], 0x0A, "LD 0x0A"),
    (1, OUT[0],    OUT[1],    0x00, "OUT"),
    (2, LD_IMM[0], LD_IMM[1], 0x01, "LD 0x01"),
    (3, ST[0],     ST[1],     0x80, "ST [0x80]"),
    (4, LD_ADDR[0], LD_ADDR[1], 0x80, "LD [0x80]"),
    (5, ADD_IMM[0], ADD_IMM[1], 0x01, "ADD 0x01"),
    (6, ST[0],     ST[1],     0x80, "ST [0x80]"),
    (7, OUT[0],    OUT[1],    0x00, "OUT"),
    (8, JMP[0],    JMP[1],    0x00, "JMP 0x00"),
]

for addr, lo, hi, d, comment in steps:
    uctl_lo[addr] = lo
    uctl_hi[addr] = hi
    udata[addr] = d
    print(f"  PC={addr}: lo=0x{lo:02x} hi=0x{hi:02x} udata=0x{d:02x}  ; {comment}")

for fname, data in [("rom/uctl_lo.hex", uctl_lo), ("rom/uctl_hi.hex", uctl_hi), ("rom/udata.hex", udata)]:
    with open(fname, "w", newline="\n") as f:
        for i in range(0, 256, 16):
            chunk = data[i:i+16]
            f.write(" ".join(f"{b:02x}" for b in chunk) + "\n")
    print(f"Generated {fname}")

print("\nExpected (skip NOP): 0A, 02, 02, ... (loop)")
