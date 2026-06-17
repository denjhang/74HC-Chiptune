#!/usr/bin/env python3
"""gen_roms.py — 生成微指令 ROM (PC 直接寻址, 6 片版)

6 片: 2×161 + 3×39SF040 + 1×377
无 MUX — 所有操作经过 ALU 查表 (LD = alu_op=000 直通)

uctl 格式: [0]ac_dis  [3:1]alu_op
  NOP  = 0x01 (ac_dis=1)
  LD x = 0x00 (ac_dis=0, alu_op=000, ALU 直通 udata)
  ADD x = 0x02 (ac_dis=0, alu_op=001)
  SUB x = 0x04 (ac_dis=0, alu_op=010)

udata 格式: [7:0] 立即数
"""

import os

os.makedirs("rom", exist_ok=True)

# ============================================================
# ALU ROM — 512K×8
# 地址: udata[7:0] | AC[7:0] | alu_op[2:0]
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
        alu[addr] = d  # op=000 直通, 其他也直通

with open("rom/alu.hex", "w", newline="\n") as f:
    for i in range(0, ALU_SIZE, 16):
        chunk = alu[i:i+16]
        f.write(" ".join(f"{b:02x}" for b in chunk) + "\n")
print("Generated rom/alu.hex (512K)")

# ============================================================
# 微指令 uctl + udata — PC 直接寻址
#
# PC=0: NOP (ac_dis=1, uctl=0x01)
# PC=1: LD 0x42  uctl=0x00 udata=0x42
# PC=2: ADD 0x0A uctl=0x02 udata=0x0A
# PC=3: ADD 0x14 uctl=0x02 udata=0x14
# PC=4: SUB 0x20 uctl=0x04 udata=0x20
# PC=5: LD 0x0F  uctl=0x00 udata=0x0F
# PC=6: SUB 0x05 uctl=0x04 udata=0x05
# PC=7: LD 0xFF  uctl=0x00 udata=0xFF
# PC=8: ADD 0x01 uctl=0x02 udata=0x01
# ============================================================
uctl = bytearray(256)
udata = bytearray(256)

# PC=0 NOP
uctl[0] = 0x01  # ac_dis=1

steps = [
    (1, 0x00, 0x42),  # LD 0x42
    (2, 0x02, 0x0A),  # ADD 0x0A
    (3, 0x02, 0x14),  # ADD 0x14
    (4, 0x04, 0x20),  # SUB 0x20
    (5, 0x00, 0x0F),  # LD 0x0F
    (6, 0x04, 0x05),  # SUB 0x05
    (7, 0x00, 0xFF),  # LD 0xFF
    (8, 0x02, 0x01),  # ADD 0x01
]
for addr, c, d in steps:
    uctl[addr] = c
    udata[addr] = d

with open("rom/uctl.hex", "w", newline="\n") as f:
    for i in range(0, 256, 16):
        chunk = uctl[i:i+16]
        f.write(" ".join(f"{b:02x}" for b in chunk) + "\n")
with open("rom/udata.hex", "w", newline="\n") as f:
    for i in range(0, 256, 16):
        chunk = udata[i:i+16]
        f.write(" ".join(f"{b:02x}" for b in chunk) + "\n")

print("Generated rom/uctl.hex, rom/udata.hex")
print("Expected: 42 -> 4C -> 60 -> 40 -> 0F -> 0A -> FF -> 00")
