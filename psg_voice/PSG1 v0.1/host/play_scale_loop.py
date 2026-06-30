#!/usr/bin/env python3
# play_scale_loop.py — 无限循环播放 C 大调音阶 (后台运行)
# Ctrl+C 或 kill 进程停止. 停止前会静音 + 全拉低 + 关设备.

import ftd2xx
import time
import sys

BIT_LE, BIT_GATE, BIT_RST = 0, 1, 2
CLK_HZ = 125_000

# C 大调音阶 + 高音 C
SCALE = [
    ('C4', 262), ('D4', 294), ('E4', 330), ('F4', 349),
    ('G4', 392), ('A4', 440), ('B4', 494), ('C5', 523),
]

class Psg:
    def __init__(self):
        self.dev = ftd2xx.open(0)
        self.dev.resetDevice()
        self.dev.setBitMode(0x00, 0x02)
        time.sleep(0.05)
        self._c = 0x00
        self._d = 0x00
        self._w()
        self.reset()

    def _w(self):
        self.dev.write(bytes([0x80, self._d & 0xFF, 0xFF]))
        self.dev.write(bytes([0x82, self._c & 0xFF, 0xFF]))
        time.sleep(2e-3)

    def _sc(self, bit, v):
        if v: self._c |= (1 << bit)
        else: self._c &= ~(1 << bit)
        self.dev.write(bytes([0x82, self._c & 0xFF, 0xFF]))
        time.sleep(2e-3)

    def reset(self):
        self._sc(BIT_RST, 0); time.sleep(2e-3)
        self._sc(BIT_RST, 1); time.sleep(2e-3)

    def gate(self, on):
        self._sc(BIT_GATE, 1 if on else 0)

    def period(self, p):
        p = max(0, min(255, p))
        self._d = p & 0xFF
        self.dev.write(bytes([0x80, self._d, 0xFF])); time.sleep(2e-3)
        self._sc(BIT_LE, 1)
        self._sc(BIT_LE, 0)

    def freq(self, f):
        self.period(round(256 - CLK_HZ / (2 * f)))

    def close(self):
        try:
            self.gate(False)
            self._d = 0; self._c = 0; self._w()
        except: pass
        self.dev.close()

def main():
    psg = Psg()
    print("=== 无限循环 C 大调音阶 ===")
    print("停止: 在运行处点停止, 或 taskkill python. 退出前会静音.")
    i = 0
    try:
        while True:
            for name, f in SCALE:
                psg.freq(f)
                psg.gate(True)
                print(f"\r[{i+1}] {name} {f}Hz   ", end='', flush=True)
                time.sleep(0.4)
                psg.gate(False)
                time.sleep(0.08)
            i += 1
            print(f"  (第 {i} 圈)")
    except KeyboardInterrupt:
        print("\n用户停止")
    finally:
        psg.close()
        print("已静音, 设备关闭")

if __name__ == '__main__':
    main()
