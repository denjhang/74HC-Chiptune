#!/usr/bin/env python3
# test_gpio_running.py — FT232H 流水灯 (持续跑, 供插 LED 时观察)
#
# 用法: python test_gpio_running.py
# Ctrl+C 停止 (停止前会自动全灭并关闭设备)
#
# 流程: D4 -> D5 -> D6 -> D7 -> C0 -> C1 -> ... -> C7 -> 反向回扫 -> 循环
# 每个脚亮 0.25 秒, 这样你能看着哪个亮就往哪个脚插 LED.

import ftd2xx
import time
import sys

PINS = ['D4','D5','D6','D7','C0','C1','C2','C3','C4','C5','C6','C7']

def write_d(dev, val, dirm):
    dev.write(bytes([0x80, val & 0xFF, dirm & 0xFF]))

def write_c(dev, val, dirm):
    dev.write(bytes([0x82, val & 0xFF, dirm & 0xFF]))

def light(dev, pin):
    """只点亮指定 pin, 其余全灭."""
    if pin.startswith('D'):
        bit = int(pin[1])
        write_d(dev, 1 << bit, 0xF0)   # D4-D7 输出
        write_c(dev, 0x00, 0xFF)       # C 全灭
    else:
        bit = int(pin[1])
        write_d(dev, 0x00, 0xF0)       # D 全灭
        write_c(dev, 1 << bit, 0xFF)   # C 点亮

def all_off(dev):
    write_d(dev, 0x00, 0xF0)
    write_c(dev, 0x00, 0xFF)

def main():
    print("=== FT232H 流水灯 ===")
    print("按顺序点亮: ", " -> ".join(PINS))
    print("看着亮的脚插 LED (LED 正极接脚, 负极接 330Ω 到 GND)")
    print("Ctrl+C 停止\n")

    dev = ftd2xx.open(0)
    dev.resetDevice()
    dev.setBitMode(0x00, 0x02)
    time.sleep(0.05)
    all_off(dev)

    seq = PINS + list(reversed(PINS))  # 正扫+反扫
    try:
        i = 0
        while True:
            pin = seq[i % len(seq)]
            light(dev, pin)
            print(f"\r  亮: {pin}   ", end='', flush=True)
            time.sleep(0.25)
            i += 1
    except KeyboardInterrupt:
        print("\n停止")
    finally:
        all_off(dev)
        dev.close()
        print("已全灭, 设备关闭")

if __name__ == '__main__':
    main()
