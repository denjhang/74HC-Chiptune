#!/usr/bin/env python3
# test_running_all.py — FT232H 全部 16 GPIO 流水灯 (MPSSE 模式)
# D0-D7 (ADBus) + C0-C7 (ACBUS), 共 16 个脚, 持续正扫+反扫.

import ftd2xx
import time

PINS = ['D0','D1','D2','D3','D4','D5','D6','D7',
        'C0','C1','C2','C3','C4','C5','C6','C7']

def main():
    print("=== FT232H 16 GPIO 流水灯 (MPSSE) ===")
    print("顺序:", " -> ".join(PINS))
    print("看着亮的脚插 LED (正极接脚, 负极接 330Ω 到 GND). Ctrl+C 停止\n")

    dev = ftd2xx.open(0)
    dev.resetDevice()
    dev.setBitMode(0x00, 0x02)  # MPSSE
    time.sleep(0.05)
    # 全灭, 全输出
    dev.write(bytes([0x80, 0x00, 0xFF]))  # D 口全输出, 全低
    dev.write(bytes([0x82, 0x00, 0xFF]))  # C 口全输出, 全低

    seq = PINS + list(reversed(PINS))
    try:
        i = 0
        while True:
            pin = seq[i % len(seq)]
            port = pin[0]
            bit = int(pin[1])
            if port == 'D':
                dev.write(bytes([0x82, 0x00, 0xFF]))            # C 全灭
                dev.write(bytes([0x80, 1 << bit, 0xFF]))        # D 点亮一个
            else:
                dev.write(bytes([0x80, 0x00, 0xFF]))            # D 全灭
                dev.write(bytes([0x82, 1 << bit, 0xFF]))        # C 点亮一个
            print(f"\r  亮: {pin}    ", end='', flush=True)
            time.sleep(0.25)
            i += 1
    except KeyboardInterrupt:
        print("\n停止")
    finally:
        dev.write(bytes([0x80, 0x00, 0xFF]))
        dev.write(bytes([0x82, 0x00, 0xFF]))
        dev.close()
        print("已全灭, 设备关闭")

if __name__ == '__main__':
    main()
