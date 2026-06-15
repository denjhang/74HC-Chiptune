#!/usr/bin/env python3
# gen_wsg3_microcode.py — Pac-Man 风格微码 ROM
# 16×4 bit 控制字, 每 4 拍处理 1 个通道

# 微码位定义 (按 Pac-Man 文档):
# bit 15: 清零加法器 (异步复位)
# bit 14: 未用
# bit 13: 未用
# bit 12: 锁存加法结果到累加器
# bit 11: 加法结果保存
# bit 10: 未用
# bit 9: 未用
# bit 8: 上升沿锁存音量和波形到输出

# 根据 Pac-Man 文档第 209 行的 case 语句生成
# 每个通道占 4 拍: 频率加法 × 4/5 次 + 波形输出

# 控制字常量
CLEAR_ADDER = 0b10000000  # bit 15: 清零
LATCH_ACC   = 0b00010000  # bit 12: 锁存到累加器
SAVE_ADDER  = 0b00001000  # bit 11: 保存结果
LATCH_OUT   = 0b00000001  # bit 8: 锁存输出

# 生成微码 (每个通道 4 拍, 3 通道 = 12 拍, 填充到 16 拍)
microcode = []

# 通道 0 (4 拍)
microcode.append(CLEAR_ADDER)           # 拍 0: 清零
microcode.append(0)                      # 拍 1: 加频率低 nibble
microcode.append(LATCH_ACC | SAVE_ADDER) # 拍 2: 锁存结果
microcode.append(LATCH_OUT)              # 拍 3: 锁存输出

# 通道 1 (4 拍)
microcode.append(CLEAR_ADDER)
microcode.append(0)
microcode.append(LATCH_ACC | SAVE_ADDER)
microcode.append(LATCH_OUT)

# 通道 2 (4 拍)
microcode.append(CLEAR_ADDER)
microcode.append(0)
microcode.append(LATCH_ACC | SAVE_ADDER)
microcode.append(LATCH_OUT)

# 填充 (12-15)
microcode.extend([0] * 4)

# 写 hex 文件 (每行一个字节, 高位在前)
with open('wsg3_microcode.hex', 'w') as f:
    for byte in microcode:
        f.write(f'{byte:02X}\n')

print(f'Generated wsg3_microcode.hex: {len(microcode)} bytes (16 steps × 4-bit control)')
