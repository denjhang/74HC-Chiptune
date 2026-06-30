#!/usr/bin/env python3
# test_gpio_selfcheck.py — FT232H GPIO 自检 (无需 LED, 回读验证)
#
# 每个 GPIO: 写高 -> 回读应高 -> 写低 -> 回读应低. 报告每个脚是否正确响应.
# 这能验证 GPIO 是否真的被 MPSSE 控制 (不用接 LED).
#
# 读命令: 0x81 读 ADBus (D0-D7), 0x83 读 ACBUS (C0-C7)
# 写命令: 0x80/0x82

import ftd2xx
import time

PINS = [
    ('D', 4, 'D4'),  ('D', 5, 'D5'),  ('D', 6, 'D6'),  ('D', 7, 'D7'),
    ('C', 0, 'C0'),  ('C', 1, 'C1'),  ('C', 2, 'C2'),  ('C', 3, 'C3'),
    ('C', 4, 'C4'),  ('C', 5, 'C5'),  ('C', 6, 'C6'),  ('C', 7, 'C7'),
]

def write_gpio(dev, val, dirm, is_cbus):
    dev.write(bytes([0x82 if is_cbus else 0x80, val & 0xFF, dirm & 0xFF]))

def read_gpio(dev, is_cbus):
    # 发读命令, 清空输入缓冲, 读回 1 字节
    dev.purge(1)  # 清 RX buffer
    dev.write(bytes([0x83 if is_cbus else 0x81]))
    time.sleep(0.01)
    data = dev.read(1)
    return data[0] if isinstance(data, (bytes, bytearray)) and len(data) else -1

def main():
    print("=== FT232H GPIO 自检 (回读验证, 无需 LED) ===\n")

    dev = ftd2xx.open(0)
    dev.resetDevice()
    dev.setBitMode(0x00, 0x02)  # MPSSE
    time.sleep(0.05)

    # 全设输出, 初始全低
    write_gpio(dev, 0x00, 0xF0, False)
    write_gpio(dev, 0x00, 0xFF, True)
    time.sleep(0.05)

    results = []
    for port, bit, name in PINS:
        is_cbus = (port == 'C')
        dirm = 0xFF if is_cbus else 0xF0

        # 写高
        write_gpio(dev, 1 << bit, dirm, is_cbus)
        time.sleep(0.02)
        rh = read_gpio(dev, is_cbus)
        high_ok = (rh >= 0) and bool((rh >> bit) & 1)

        # 写低
        write_gpio(dev, 0x00, dirm, is_cbus)
        time.sleep(0.02)
        rl = read_gpio(dev, is_cbus)
        low_ok = (rl >= 0) and not bool((rl >> bit) & 1)

        status = "OK" if (high_ok and low_ok) else "FAIL"
        results.append((name, high_ok, low_ok, rh, rl, status))
        rd = f"H=0x{rh:02x}" if rh>=0 else "H=ERR"
        ld = f"L=0x{rl:02x}" if rl>=0 else "L=ERR"
        mark_h = "1" if high_ok else "0"
        mark_l = "0" if low_ok else "1"
        print(f"{name:4s} [{status:4s}]  写高->读{mark_h} 写低->读{mark_l}  ({rd} {ld})")

    write_gpio(dev, 0x00, 0xF0, False)
    write_gpio(dev, 0x00, 0xFF, True)
    dev.close()

    ok = sum(1 for r in results if r[5]=="OK")
    print(f"\n=== 结果: {ok}/{len(results)} 个 GPIO 自检通过 ===")
    if ok == len(results):
        print(">>> 12 个 GPIO 全部可控, 可以接 PSG <<<")
    else:
        bad = [r[0] for r in results if r[5]!="OK"]
        print(f">>> 异常引脚: {', '.join(bad)} <<<")

if __name__ == '__main__':
    main()
