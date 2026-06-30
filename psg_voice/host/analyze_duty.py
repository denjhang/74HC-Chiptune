#!/usr/bin/env python3
# 分析重装架构下 count 各 bit 的占空比, 找最接近 50% 方波的输出位
# count 从 period 线性数到 255, 然后重装回 period (循环)

CLK_HZ = 64000

def analyze_bit(period, bit):
    """计算 count 在 [period, 255] 循环时, bit 位的占空比."""
    steps = 256 - period
    if steps <= 0:
        return None
    high_count = 0
    for c in range(period, 256):
        if (c >> bit) & 1:
            high_count += 1
    duty = high_count / steps
    # 该 bit 的翻转频率 (每次过 period~255 循环翻转的次数)
    # 实际频率 = 翻转次数 / 2 / 循环时间  (除2因为两次翻转才一个完整周期)
    return duty

print("=== 重装架构下 count 各 bit 占空比分析 (clk=64kHz) ===\n")
print(f"{'音':4} {'freq':7} {'period':7} ", end='')
for b in range(8):
    print(f"bit{b} ", end='')
print()

for name, freq in [('C3',130.8),('C4',261.6),('C5',523.3),('A5',880),('C6',1046.5),('A6',1760),('C7',2093),('C8',4186)]:
    period = round(256 - CLK_HZ / (2 * freq))
    if not (0 <= period <= 255):
        continue
    print(f"{name:4} {freq:7.1f} {period:7} ", end='')
    for b in range(8):
        d = analyze_bit(period, b)
        if d is None:
            print("  -- ", end='')
        else:
            # 标记接近 50% 的
            mark = '*' if 0.3 <= d <= 0.7 else ' '
            print(f"{d*100:3.0f}%{mark}", end='')
    print()

print()
print("* = 占空比 30%~70% (接近方波, 听感较纯)")
print("其他占空比 = 窄脉冲/宽脉冲 (谐波多)")
