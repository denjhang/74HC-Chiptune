#!/usr/bin/env python3
# gen_prom3m.py — 生成 3M 微码 ROM (39SF040 512KB)
#
# Pac-Man 原版 16-bit 微码字 (见 reference 文档第 209-211 行):
#   每个 TDM step (HCNT[5:2]) 对应 4 个 sub-cycle (HCNT[1:0]=00,01,10,11)
#   每个 sub-cycle 4 个控制 bit:
#     bit[3] = ~clr174_n (0=异步清零加法器)
#     bit[2] = ~acc_we_n (0=写累加器到 RAM)
#     bit[1] = cp273     (上升沿锁存输出 273)
#     bit[0] = clk174    (上升沿锁存 carry chain)
#
# 16-bit 编码示例 (step 0): 1101_1110_1111_0111
#   MSnibble [15:12]=1101 → HCNT[1:0]=00 相位: acc_we=1, clr=1, clk174=1
#   [11:8]      =1110 → HCNT[1:0]=01 相位: idle (clk=0)
#   [7:4]       =1111 → HCNT[1:0]=10 相位: idle
#   [3:0]       =0111 → HCNT[1:0]=11 相位: clr=0 (异步清零加法器)
#
# 地址布局 (我们用 6-bit HCNT 全部):
#   A[5:2] = TDM step (0-15)
#   A[1:0] = sub-cycle (0-3)
#   每个 cell 1 byte (低 4 bit 用)

ROM_SIZE = 512 * 1024  # 39SF040 = 512KB

# 控制 bit 定义 (Pac-Man 原版)
#     bit[3] = ~clr174_n (0=异步清零 carry chain, 1=不清零)
#     bit[2] = ~acc_we_n (0=写加法结果回 acc RAM, 1=不写)
#     bit[1] = cp273     (1=上升沿锁存输出, 0=不锁存)
#     bit[0] = clk174    (1=上升沿锁存 carry chain, 0=不锁存)
CLR_N   = 0b1000  # bit[3]=1 (不清零)
ACC_WE  = 0b0000  # bit[2]=0 (写 acc)
CP273   = 0b0010  # bit[1]=1 (锁存输出)
CLK174  = 0b0001  # bit[0]=1 (锁存 carry)

# 修改后的 16-bit 微码字
#   step 0 (ch0 nibble 0, clear + write acc):  1101_1110_1111_0011 = 0xDE73
#   step 1-4 (ch0 nibble 1-4):           1101_1110_1111_1111 = 0xDEFF
#   step 5 (ch0 output):                 1011_1111_1111_1111 = 0xBFFF
#   step 6, B (ch1/ch2 nibble 0, clear+write): 0xDE73
#   step 7-9, C-E:                       0xDEFF
#   step A, F (ch1/ch2 output):          0xBFFF
rom3m_16bit = [
    0xDEF7,  # step 0: ch0 nibble 0, clear adder
    0xDEFF,  # step 1: ch0 nibble 1
    0xDEFF,  # step 2: ch0 nibble 2
    0xDEFF,  # step 3: ch0 nibble 3
    0xDEFF,  # step 4: ch0 nibble 4 (5 nibbles = 20-bit)
    0xBFFF,  # step 5: ch0 output
    0xDEF7,  # step 6: ch1 nibble 0, clear adder
    0xDEFF,  # step 7: ch1 nibble 1
    0xDEFF,  # step 8: ch1 nibble 2
    0xDEFF,  # step 9: ch1 nibble 3
    0xBFFF,  # step A: ch1 output
    0xDEF7,  # step B: ch2 nibble 0, clear adder
    0xDEFF,  # step C: ch2 nibble 1
    0xDEFF,  # step D: ch2 nibble 2
    0xDEFF,  # step E: ch2 nibble 3
    0xBFFF,  # step F: ch2 output
]

assert len(rom3m_16bit) == 16

# 展开到 64 cells (16 step × 4 sub-cycle)
# 16-bit word 布局: MSB nibble[15:12] = sub0, LSB nibble[3:0] = sub3
# 文档示例: 1101_1110_1111_0111
#   sub0=1101, sub1=1110, sub2=1111, sub3=0111
rom = bytearray([0xFF] * ROM_SIZE)
for step in range(16):
    word = rom3m_16bit[step]
    for sub in range(4):
        nibble = (word >> (4 * (3 - sub))) & 0xF  # MSB first
        addr = (step << 2) | sub
        rom[addr] = nibble

# 输出 hex 文件 (空格分隔, 小写, 每行 16 字节避免单行过长)
# iverilog $readmemh 在每行 1 字节大写格式下有解析 bug, 必须空格分隔
with open("wsg3_prom3m.hex", "w", newline="\n") as f:
    for chunk_start in range(0, len(rom), 16):
        chunk = rom[chunk_start:chunk_start+16]
        f.write(" ".join(f"{b:02x}" for b in chunk) + "\n")

print(f"Generated wsg3_prom3m.hex ({ROM_SIZE} bytes)")
print("First 64 bytes (microcode, 16 step × 4 sub-cycle):")
for step in range(16):
    cells = " ".join(f"{rom[step*4 + sub]:04b}" for sub in range(4))
    print(f"  step {step:X}: sub0={rom[step*4+0]:04b} sub1={rom[step*4+1]:04b} "
          f"sub2={rom[step*4+2]:04b} sub3={rom[step*4+3]:04b}")
