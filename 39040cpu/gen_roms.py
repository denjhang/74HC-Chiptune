#!/usr/bin/env python3
"""gen_roms.py — 生成微指令 ROM (22 片版, 含条件分支)

22 片: 5×161 + 4×39SF040 + 4×377 + 4×157 + 1×62256 + 2×02 + 1×08 + 1×04

uctl_lo (8-bit, 负逻辑编码):
  [0]   ac_dis_n  (1=禁止AC)
  [3:1] alu_op    (000=直通, 001=ADD, 010=SUB)
  [4]   bus_sel   (0=udata, 1=ram_do)
  [5]   ram_we_n  (1=禁止写SRAM)
  [6]   mem_sel   (0=udata地址, 1=x_reg地址)
  [7]   to_x_n    (1=禁止锁存X)

uctl_hi (8-bit):
  [0]   jmp_dis_n (0=JMP使能, 负逻辑)
  [1]   to_y_n    (1=禁止锁存Y)
  [2]   to_out_n  (1=禁止锁存OUT)
  [3]   cond_en   (1=条件分支使能)
  [4]   cond_sel  (0=always, 1=zero)
  [7:5] 预留

指令编码:
  NOP        lo=0x21 hi=0xFF  (ac_dis_n=1, jmp_dis_n=1)
  LD #imm    lo=0x20 hi=0xFF  (ram_we_n=1)
  ADD #imm   lo=0x22 hi=0xFF  (alu_op=001)
  SUB #imm   lo=0x24 hi=0xFF  (alu_op=010)
  LD [addr]  lo=0x30 hi=0xFF  (bus_sel=1)
  ST [addr]  lo=0x01 hi=0xFF  (ac_dis_n=1, ram_we_n=0)
  ADD [addr] lo=0x32 hi=0xFF  (alu_op=001, bus_sel=1)
  OUT        lo=0xA7 hi=0xFB  (ac_dis_n=1, alu_op=011=PASS_AC, to_out_n=0)
  JMP addr   lo=0x21 hi=0xEE  (ac_dis_n=1, jmp_dis_n=0, cond_en=1, cond_sel=0)
  JZ addr    lo=0x21 hi=0xFE  (ac_dis_n=1, jmp_dis_n=0, cond_en=1, cond_sel=1)
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
    elif op == 0b011:
        alu[addr] = acc  # PASS_AC: output accumulator
    else:
        alu[addr] = d

with open("rom/alu.hex", "w", newline="\n") as f:
    for i in range(0, ALU_SIZE, 16):
        chunk = alu[i:i+16]
        f.write(" ".join(f"{b:02x}" for b in chunk) + "\n")
print("Generated rom/alu.hex (512K)")

# ============================================================
# 测试程序: 条件分支 + 计数器
#
# 目标: 用 JZ 实现循环, 计数到 5 然后退出
#
# PC=0:  LD 0x05       ; AC=5 (计数初值)
# PC=1:  OUT            ; out=AC
# PC=2:  SUB 0x01       ; AC--
# PC=3:  JZ  0x05       ; if AC==0, jump to PC=5 (exit)
# PC=4:  JMP 0x01       ; else jump to PC=1 (loop)
# PC=5:  LD 0xAA       ; AC=0xAA (exit marker)
# PC=6:  OUT            ; out=0xAA
# PC=7:  JMP 0x07       ; 死循环 (halt)
#
# 预期输出: 05, 04, 03, 02, 01, 00, AA, AA, AA, ...
#           (循环 5 次, 然后 0xAA 停机)
# ============================================================
uctl_lo = bytearray(256)
uctl_hi = bytearray(256)
udata = bytearray(256)

NOP = (0x21, 0xFF)
LD_IMM = (0x20, 0xFF)
ADD_IMM = (0x22, 0xFF)
SUB_IMM = (0x24, 0xFF)
ST = (0x01, 0xFF)
LD_ADDR = (0x30, 0xFF)
ADD_ADDR = (0x32, 0xFF)
OUT = (0xA7, 0xFB)      # ac_dis_n=1, alu_op=011 (PASS_AC), to_out_n=0
JMP = (0x21, 0xEE)      # jmp_dis_n=0, cond_en=1, cond_sel=0 (always)
JZ = (0x21, 0xFE)       # jmp_dis_n=0, cond_en=1, cond_sel=1 (zero)

steps = [
    # (PC, lo, hi, udata, comment)
    (0, LD_IMM[0],  LD_IMM[1],  0x05, "LD 0x05"),
    (1, OUT[0],     OUT[1],     0x00, "OUT"),
    (2, SUB_IMM[0], SUB_IMM[1], 0x01, "SUB 0x01"),
    (3, JZ[0],      JZ[1],      0x05, "JZ 0x05"),
    (4, JMP[0],     JMP[1],     0x01, "JMP 0x01"),
    (5, LD_IMM[0],  LD_IMM[1],  0xAA, "LD 0xAA"),
    (6, OUT[0],     OUT[1],     0x00, "OUT"),
    (7, JMP[0],     JMP[1],     0x07, "JMP 0x07 (halt)"),
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

print("\nExpected: 05, 04, 03, 02, 01, 00, AA, AA, ... (5 loops + halt)")
