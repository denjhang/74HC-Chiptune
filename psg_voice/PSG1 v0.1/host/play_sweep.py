#!/usr/bin/env python3
# play_sweep.py — C 大调快速扫频 (最低→最高→最低)
#
# 规则:
#   - 每音响 0.2 秒, 间隔 0.1 秒
#   - 八度音 (C 音: C4/C5/C6) 响 5 次 (每次 0.2s 响 + 0.1s 间隔)
#   - 其他音响 1 次
#   - 从最低扫到最高, 再扫回最低, 循环

import ftd2xx
import time

BIT_LE, BIT_GATE, BIT_RST = 0, 1, 2
CLK_HZ = 125_000

# C 大调音阶 (PSG @125kHz 覆盖范围 C4~C6)
# freq, period = 256 - 125000/(2*f)
SCALE = [
    ('C4', 262), ('D4', 294), ('E4', 330), ('F4', 349),
    ('G4', 392), ('A4', 440), ('B4', 494),
    ('C5', 523), ('D5', 587), ('E5', 659), ('F5', 698),
    ('G5', 784), ('A5', 880), ('B5', 988),
    ('C6', 1047),
]

NOTE_ON_T  = 0.2   # 每音响 0.2 秒
GAP_T      = 0.1   # 音间间隔 0.1 秒
OCTAVE_HIT = 5     # 八度音 (C) 响 5 次

def is_octave(name):
    """C 音是八度音."""
    return name.startswith('C')

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

    def hit(self, freq):
        """响一次: 写频率 -> 开 gate -> NOTE_ON_T -> 关 gate -> GAP_T."""
        self.freq(freq)
        self.gate(True)
        time.sleep(NOTE_ON_T)
        self.gate(False)
        time.sleep(GAP_T)

    def close(self):
        try:
            self.gate(False)
            self._d = 0; self._c = 0; self._w()
        except: pass
        self.dev.close()


def play_note(psg, name, freq):
    """按规则播放一个音: 八度音响 5 次, 其他响 1 次."""
    hits = OCTAVE_HIT if is_octave(name) else 1
    tag = f" ({hits}x)" if hits > 1 else ""
    print(f"  {name} {freq}Hz{tag}", flush=True)
    for _ in range(hits):
        psg.hit(freq)

def main():
    psg = Psg()
    try:
        while True:
            # 上行: C4 -> C6
            print("=== 上行 C4 -> C6 ===", flush=True)
            for name, freq in SCALE:
                play_note(psg, name, freq)
            # 下行: C6 -> C4 (跳过已响的 C6, 从 B5 开始)
            print("=== 下行 C6 -> C4 ===", flush=True)
            for name, freq in reversed(SCALE[1:]):
                play_note(psg, name, freq)
    except KeyboardInterrupt:
        print("\n停止")
    finally:
        psg.close()
        print("已静音, 设备关闭")

if __name__ == '__main__':
    main()
