#!/usr/bin/env python3
# psg_ft232h.py — FT232H 控制 PSG (修正版: period 用 C0-C7, 控制用 D4-D6)
#
# 修正原因: MPSSE 模式下 D1(TDI)/D2(TDO) 被强制拉高, 无法写低.
#          所以 period 数据改用 ACBUS C0-C7 (完全可控), 控制信号挪到 D4-D6.
#
# 引脚分配 (修正后):
#   C0-C7  -> period_in[7:0]  (ACBUS, 0x82 命令写, 全可控)
#   D4     -> period_le       (ADBUS bit4, LE 高=透明/低=锁存)
#   D5     -> gate            (ADBUS bit5, 1=发声/0=静音)
#   D6     -> rst_n           (ADBUS bit6, 低有效复位)
#
# 频率公式 (@125kHz): f = 125000 / (2*(256-period))

import ftd2xx
import time

# 控制位 (在 ADBus D 口内的 bit)
BIT_LE   = 4  # D4
BIT_GATE = 5  # D5
BIT_RST  = 6  # D6

CLK_HZ = 125_000

class PsgFt232h:
    def __init__(self, dev_index=0):
        self.dev = ftd2xx.open(dev_index)
        self.dev.resetDevice()
        self.dev.setBitMode(0x00, 0x02)  # MPSSE
        time.sleep(0.05)
        self._d = 0x00   # D 口 (控制信号: D4/D5/D6)
        self._c = 0x00   # C 口 (period 数据: C0-C7)
        self._write_both()
        self.reset()

    def _write_both(self):
        self.dev.write(bytes([0x80, self._d & 0xFF, 0xFF]))  # D 口全输出
        self.dev.write(bytes([0x82, self._c & 0xFF, 0xFF]))  # C 口全输出
        time.sleep(2e-3)

    def _set_d(self, bit, val):
        """改 D 口某位 (控制信号)."""
        if val: self._d |= (1 << bit)
        else:   self._d &= ~(1 << bit)
        self.dev.write(bytes([0x80, self._d & 0xFF, 0xFF]))
        time.sleep(2e-3)

    def reset(self):
        self._set_d(BIT_RST, 0); time.sleep(2e-3)
        self._set_d(BIT_RST, 1); time.sleep(2e-3)

    def set_gate(self, on):
        self._set_d(BIT_GATE, 1 if on else 0)

    def set_period(self, period):
        """写 period: C 口放数据 + D4 LE 脉冲."""
        period = max(0, min(255, period))
        self._c = period & 0xFF
        self.dev.write(bytes([0x82, self._c, 0xFF]))  # C 口 = period
        time.sleep(2e-3)
        self._set_d(BIT_LE, 1)  # LE 高 (透明)
        self._set_d(BIT_LE, 0)  # LE 低 (锁存)

    def set_freq(self, freq_hz):
        period = round(256 - CLK_HZ / (2 * freq_hz))
        self.set_period(period)
        return CLK_HZ / (2 * (256 - period))

    def note_on(self, freq_hz):
        self.set_freq(freq_hz)
        self.set_gate(True)

    def note_off(self):
        self.set_gate(False)

    def hit(self, freq, on_t=0.2, gap_t=0.1):
        self.set_freq(freq)
        self.set_gate(True)
        time.sleep(on_t)
        self.set_gate(False)
        time.sleep(gap_t)

    def close(self):
        try:
            self.set_gate(False)
            self._d = 0; self._c = 0
            self._write_both()
        except: pass
        self.dev.close()


if __name__ == '__main__':
    SCALE = [
        ('C4', 262), ('D4', 294), ('E4', 330), ('F4', 349),
        ('G4', 392), ('A4', 440), ('B4', 494),
        ('C5', 523), ('D5', 587), ('E5', 659), ('F5', 698),
        ('G5', 784), ('A5', 880), ('B5', 988), ('C6', 1047),
    ]
    psg = PsgFt232h()
    try:
        psg.reset()
        print("=== 修正版 (period 用 C 口) C 大调音阶 ===")
        for name, freq in SCALE:
            actual = psg.set_freq(freq)
            print(f"  {name} {freq}Hz -> period={256-round(125000/(2*freq))} 实测{actual:.1f}Hz")
            psg.set_gate(True)
            time.sleep(0.3)
            psg.set_gate(False)
            time.sleep(0.05)
        print("完成")
    finally:
        psg.close()
