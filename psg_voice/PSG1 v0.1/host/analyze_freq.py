#!/usr/bin/env python3
# 分析各 bit 的实际输出频率 (不只是占空比)
# count 从 period 到 255 循环, 每个 bit 的翻转产生什么频率

CLK_HZ = 64000

def bit_freq_and_duty(period, bit):
    """count 在 [period,255] 循环, 返回 bit 的频率和占空比."""
    seq = list(range(period, 256)) * 2  # 两个循环, 看周期性
    bits = [(c >> bit) & 1 for c in seq]
    # 数上升沿
    rises = 0
    high = 0
    for i in range(len(bits)):
        if bits[i]: high += 1
        if i > 0 and bits[i] == 1 and bits[i-1] == 0:
            rises += 1
    if rises == 0:
        return 0, (1.0 if bits[0] else 0.0)
    # 一个完整循环 = (256-period) 个 clk
    # rises 在 2 个循环里
    cycle_clks = 256 - period
    freq = CLK_HZ * (rises / 2) / cycle_clks  # rises/2 = 每循环上升沿数
    duty = high / len(bits)
    return freq, duty

print("=== 各 bit 的实际频率 + 占空比 (clk=64kHz) ===\n")
print(f"{'音':4} {'目标freq':8} {'period':7} | ", end='')
for b in range(4):
    print(f"  bit{b}(Hz/duty)  ", end='')
print()

for name, freq in [('C3',130.8),('C4',261.6),('C5',523.3),('A5',880),('C6',1046.5),('A6',1760),('C7',2093)]:
    period = round(256 - CLK_HZ / (2 * freq))
    if not (0 <= period <= 255): continue
    print(f"{name:4} {freq:8.1f} {period:7} | ", end='')
    for b in range(4):
        f, d = bit_freq_and_duty(period, b)
        print(f"{f:6.0f}/{d*100:.0f}% ", end='')
    print()
