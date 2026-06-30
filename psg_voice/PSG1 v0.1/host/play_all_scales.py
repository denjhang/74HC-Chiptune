#!/usr/bin/env python3
# play_all_scales.py — 演奏全部 12 个大调音阶
#
# 顺序 (按五度圈, 升号调 → 降号调):
#   C, G, D, A, E, B, F#, Db/Dbm, Ab, Eb, Bb, F  (Db 用 C# 等价)
#
# 每个调: 从主音上行一个八度再到主音 (do re mi fa sol la si do)
# 每音 0.25 秒, 间隔 0.05 秒
# 调之间停 0.8 秒
#
# 用等音方便实现: B#=C, E#=F, Fb=E, Cb=B, E#=F 等

import ftd2xx
import time

BIT_LE, BIT_GATE, BIT_RST = 4, 5, 6  # D4/D5/D6
CLK_HZ = 125_000
NOTE_T = 0.25
GAP_T  = 0.05
KEY_GAP = 0.8

# 12 平均律, 以 A4=440 为基准, midi number -> freq
def midi_to_freq(m):
    return 440.0 * (2 ** ((m - 69) / 12.0))

# 各大调的音阶 (midi number), 起点选在 C4(60) 附近, 保证频率在 PSG 范围内
# 大调音程: 全 全 半 全 全 全 半
# 用 midi 偏移构造: 0,2,4,5,7,9,11,12
MAJOR_INTERVALS = [0, 2, 4, 5, 7, 9, 11, 12]

# 12 个大调, 主音的 midi (从 C4=60 开始, 五度圈顺序)
# C G D A E B F#/Db C#/Db(用Db) Ab Eb Bb F
KEYS = [
    ('C',  60),   # C4
    ('G',  67),   # G4
    ('D',  62),   # D4
    ('A',  69),   # A4
    ('E',  64),   # E4
    ('B',  71),   # B4
    ('F#', 66),   # F#4
    ('Db', 61),   # Db4 (= C#4)
    ('Ab', 68),   # Ab4
    ('Eb', 63),   # Eb4
    ('Bb', 70),   # Bb4
    ('F',  65),   # F4
]

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

    def note(self, f):
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


def main():
    psg = Psg()
    try:
        while True:
            for key_name, root_midi in KEYS:
                # 构造音阶: 主音 + 大调音程, 上行 8 音
                notes = [(root_midi + interval) for interval in MAJOR_INTERVALS]
                print(f"=== {key_name} 大调 ===", flush=True)
                for m in notes:
                    f = midi_to_freq(m)
                    name = midi_name(m)
                    print(f"  {name} ({f:.1f}Hz)", flush=True)
                    psg.note(f)
                time.sleep(KEY_GAP)
            print("\n=== 12 大调全部完成, 重新开始 ===\n")
    except KeyboardInterrupt:
        print("\n停止")
    finally:
        psg.close()
        print("已静音, 设备关闭")

# 音名映射 (midi -> name)
NAMES = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B']
def midi_name(m):
    octave = m // 12 - 1
    return f"{NAMES[m % 12]}{octave}"

if __name__ == '__main__':
    main()
