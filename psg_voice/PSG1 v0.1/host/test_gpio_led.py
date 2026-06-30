#!/usr/bin/env python3
# test_gpio_led.py — FT232H 逐个 GPIO 点灯测试
#
# 测试 12 个 GPIO, 每个脚轮流拉高 1 秒再拉低.
# 接法: 每个被测脚串一个 LED + 330Ω 电阻到 GND.
#       (FT232H 输出约 3.3V, LED 正极接 GPIO, 负极接电阻到 GND)
#
# MPSSE GPIO 写命令:
#   0x80 value direction  -> 写 ADBus (D0-D7, 低 8 位)
#   0x82 value direction  -> 写 ACBUS (C0-C7, 高 8 位)
#   direction: 1=输出, 0=输入. value: 该位的电平.

import ftd2xx
import time
import sys

# GPIO 定义: (端口, 位号, 名称)
# 端口 'D' = ADBus (用 0x80 命令), 'C' = ACBUS (用 0x82 命令)
PINS = [
    ('D', 4, 'D4'),  ('D', 5, 'D5'),  ('D', 6, 'D6'),  ('D', 7, 'D7'),
    ('C', 0, 'C0'),  ('C', 1, 'C1'),  ('C', 2, 'C2'),  ('C', 3, 'C3'),
    ('C', 4, 'C4'),  ('C', 5, 'C5'),  ('C', 6, 'C6'),  ('C', 7, 'C7'),
]

def write_gpio(dev, port_bits, dir_bits, is_cbus):
    """写一组 GPIO: 同时设置 direction 和 value."""
    cmd = bytes([0x82 if is_cbus else 0x80, port_bits & 0xFF, dir_bits & 0xFF])
    dev.write(cmd)

def main():
    print("=== FT232H GPIO 逐个点灯测试 ===")
    print(f"共 {len(PINS)} 个 GPIO, 每个亮 0.8 秒\n")
    print("接法: GPIO -> LED 正极 -> 330Ω -> GND")
    print("观察: 哪个 LED 亮, 对应引脚就是好的\n")

    dev = ftd2xx.open(0)
    dev.resetDevice()

    # 切 MPSSE 模式, 全部 12 个 GPIO 方向先设为输出
    # ADBus: D4-D7 = bit4-7 输出 -> dir 低字节 = 0xF0 (D0-D3 留给 SPI 不动, 这里先设 0)
    # ACBUS: C0-C7 全输出 -> dir 高字节 = 0xFF
    dev.setBitMode(0x00, 0x02)
    time.sleep(0.05)

    # 初始: 全部输出低 (灯灭)
    write_gpio(dev, 0x00, 0xF0, is_cbus=False)  # D4-D7 输出低
    write_gpio(dev, 0x00, 0xFF, is_cbus=True)   # C0-C7 输出低
    time.sleep(0.3)
    print("初始: 所有 GPIO 拉低 (灯应全灭)\n")

    try:
        for idx, (port, bit, name) in enumerate(PINS):
            is_cbus = (port == 'C')

            # 置高这一个脚
            if is_cbus:
                write_gpio(dev, 0x00, 0xFF, True)              # C 口先全低
                write_gpio(dev, 1 << bit, 0xFF, True)          # 只拉高这一个 C 位
            else:
                write_gpio(dev, 0x00, 0xF0, False)             # D 口先全低
                write_gpio(dev, 1 << bit, 0xF0, False)         # 只拉高这一个 D 位

            print(f"[{idx+1:2d}/{len(PINS)}] {name}  HIGH  <- 亮 0.8s", flush=True)
            time.sleep(0.8)

            # 拉低
            if is_cbus:
                write_gpio(dev, 0x00, 0xFF, True)
            else:
                write_gpio(dev, 0x00, 0xF0, False)
            time.sleep(0.2)

        print("\n=== 全部测试完成 ===")
        print("正常情况: 每个 GPIO 对应的 LED 应顺序亮灭 12 次")
        print("不亮的脚: 检查接线/LED 方向/电阻")

    except KeyboardInterrupt:
        print("\n用户中断")
    finally:
        # 收尾: 全拉低, 关闭设备
        write_gpio(dev, 0x00, 0xF0, False)
        write_gpio(dev, 0x00, 0xFF, True)
        dev.close()
        print("设备已关闭, 所有 GPIO 已拉低")

if __name__ == '__main__':
    main()
