#!/usr/bin/env python3
# play_sweep_low.py — C 大调跨八度扫频 (C3 -> C8 -> C3)
#
# 时钟: 64 kHz (外部时钟模块)
# period 公式: f = 64000 / (2*(256-period))
#
# 规则:
#   - C 大调音阶, 每个八度 7 音 (C D E F G A B)
#   - 上行 C3 -> C8, 再下行 C8 -> C3
#   - 每音 0.2 秒, 间隔 0.1 秒
#   - 八度音 (C 音) 响 5 次, 其他响 1 次

import ftd2xx
import time

BIT_LE, BIT_GATE, BIT_RST = 4, 5, 6  # D4/D5/D6
CLK_HZ = 64000
NOTE_T = 0.2
GAP_T  = 0.1
OCTAVE_HIT = 5

# midi -> freq (12 平均律, A4=440)
def m2f(m):
    return 440.0 * (2 ** ((m - 69) / 12.0))

# C 大调音阶序列: 从 C3(midi 48) 到 C8(midi 96)
# 每个八度: C D E F G A B (midi 偏移 0,2,4,5,7,9,11)
# 生成所有音 + 终点 C8
def build_scale():
    notes = []
    for octave in range(3, 8):  # C3..C7 各八度的 C D E F G A B
        base = 12 * (octave + 1)  # midi: C3=48, C4=60, ...
        for interval in [0, 2, 4, 5, 7, 9, 11]:
            notes.append(base + interval)
    notes.append(12 * 9)  # C8 (midi 96)
    return notes

class Psg:
    def __init__(self):
        self.dev = ftd2xx.open(0)
        self.dev.resetDevice()
        self.dev.setBitMode(0x00, 0x02)
        time.sleep(0.05)
        self._d = 0; self._c = 0
        self._wb()
        self.reset()

    def _wb(self):
        self.dev.write(bytes([0x80, self._d & 0xFF, 0xFF]))
        self.dev.write(bytes([0x82, self._c & 0xFF, 0xFF]))
        time.sleep(2e-3)

    def _sd(self, bit, v):
        if v: self._d |= (1 << bit)
        else: self._d &= ~(1 << bit)
        self.dev.write(bytes([0x80, self._d & 0xFF, 0xFF]))
        time.sleep(2e-3)

    def reset(self):
        self._sd(BIT_RST, 0); time.sleep(2e-3)
        self._sd(BIT_RST, 1); time.sleep(2e-3)

    def freq(self, f):
        p = max(0, min(255, round(256 - CLK_HZ / (2 * f))))
        self._c = p & 0xFF
        self.dev.write(bytes([0x82, self._c, 0xFF])); time.sleep(2e-3)
        self._sd(BIT_LE, 1); self._sd(BIT_LE, 0)
        return p

    def hit(self, f):
        self.freq(f)
        self._sd(BIT_GATE, 1)
        time.sleep(NOTE_T)
        self._sd(BIT_GATE, 0)
        time.sleep(GAP_T)

    def close(self):
        try:
            self._sd(BIT_GATE, 0)
            self._d = 0; self._c = 0; self._wb()
        except: pass
        self.dev.close()

NAMES = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B']
def m_name(m):
    return f"{NAMES[m % 12]}{m // 12 - 1}"

def play_note(psg, m):
    f = m2f(m)
    name = m_name(m)
    is_c = (m % 12 == 0)  # C 音
    hits = OCTAVE_HIT if is_c else 1
    tag = f" ({hits}x)" if hits > 1 else ""
    p = psg.freq(f)
    print(f"  {name} {f:7.1f}Hz period={p:3}{tag}", flush=True)
    for _ in range(hits):
        psg.hit(f)

def main():
    scale = build_scale()
    psg = Psg()
    try:
        while True:
            print(f"=== 上行 C1 -> C9 (clk={CLK_HZ}Hz) ===", flush=True)
            for m in scale:
                play_note(psg, m)
            print("=== 下行 C9 -> C1 ===", flush=True)
            for m in reversed(scale):
                play_note(psg, m)
    except KeyboardInterrupt:
        print("\n停止")
    finally:
        psg.close()
        print("已静音, 设备关闭")

if __name__ == '__main__':
    main()
