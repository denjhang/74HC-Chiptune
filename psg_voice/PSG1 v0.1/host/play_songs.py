#!/usr/bin/env python3
# play_songs.py — 循环播放常见儿歌/简单旋律
#
# 已编入歌曲 (按简谱):
#   1. 两只老虎 (Frère Jacques)
#   2. 小星星 (Twinkle Twinkle Little Star)
#   3. 欢乐颂 (Ode to Joy, 贝多芬第九交响曲主题)
#   4. 生日快乐 (Happy Birthday)
#
# 简谱记法:
#   音符: 1-7 (do re mi fa sol la si), 0 = 休止
#   八度: 'C4' 基准, 'C5'/'C6' 高音, 'C3' 低音 (简谱数字带点上/下点)
#   节拍: 每音用 (音符, 拍数) 表示, 1拍=0.3秒 (可调)
#   附点/长音: 拍数 1.5 或 2
#
# 时钟: 64 kHz (PSG 当前配置)
# 引脚: C0-C7 数据, D4/D5/D6 = LE/GATE/RST

import ftd2xx
import time

# ============== PSG 硬件控制 ==============
BIT_LE, BIT_GATE, BIT_RST = 4, 5, 6
CLK_HZ = 64000

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

    def play_note(self, f, beats, beat_t):
        """响一个音: beats 拍."""
        if f > 0:
            self.freq(f)
            self._sd(BIT_GATE, 1)
        time.sleep(beats * beat_t)
        self._sd(BIT_GATE, 0)
        time.sleep(0.02)  # 音间小间隔

    def close(self):
        try:
            self._sd(BIT_GATE, 0)
            self._d = 0; self._c = 0; self._wb()
        except: pass
        self.dev.close()


# ============== 简谱 -> 频率 ==============
# 简谱数字 1-7 在指定八度的频率 (A4=440, 12平均律)
# degree: 1-7 (do-si), octave: 3/4/5/6 (C3=低音, C4=中音, C5=高音)
NOTE_SEMITONE = {1:0, 2:2, 3:4, 4:5, 5:7, 6:9, 7:11}  # C大调音级->半音

def jianpu_freq(degree, octave):
    """简谱(音级1-7, 八度) -> 频率."""
    # C4 = midi 60. 音级 degree 在 octave 八度: midi = 12*(octave+1) + semitone
    midi = 12 * (octave + 1) + NOTE_SEMITONE[degree]
    return 440.0 * (2 ** ((midi - 69) / 12.0))


# ============== 歌曲数据 (简谱) ==============
# 格式: (歌名, [八度, [(音级, 拍数), ...]])
# 音级: 1-7, 0=休止; 拍数: 1=四分音符, 2=二分, 0.5=八分, 1.5=附点

SONGS = [
    # ---- 1. 两只老虎 (C4 八度) ----
    ("两只老虎", 4, [
        # 1 2 3 1 | 1 2 3 1 | 3 4 5 - | 3 4 5 -
        (1,1),(2,1),(3,1),(1,1), (1,1),(2,1),(3,1),(1,1),
        (3,1),(4,1),(5,2),       (3,1),(4,1),(5,2),
        # 5 6 5 4 3 1 | 5 6 5 4 3 1 | 1 5(低) 1 - | 1 5(低) 1 -
        # 注: 简谱 "1 5 1" 中间 5 是低音, 用特殊标记 (下面处理)
        (5,0.5),(6,0.5),(5,0.5),(4,0.5),(3,1),(1,1),
        (5,0.5),(6,0.5),(5,0.5),(4,0.5),(3,1),(1,1),
        (1,1),(1,1),(1,2),  # 简化结尾 do(低) do - , 这里用 C4
    ]),

    # ---- 2. 小星星 (C4 八度) ----
    ("小星星", 4, [
        # 1 1 5 5 6 6 5 - | 4 4 3 3 2 2 1 -
        (1,1),(1,1),(5,1),(5,1),(6,1),(6,1),(5,2),
        (4,1),(4,1),(3,1),(3,1),(2,1),(2,1),(1,2),
        # 5 5 4 4 3 3 2 - | 5 5 4 4 3 3 2 -
        (5,1),(5,1),(4,1),(4,1),(3,1),(3,1),(2,2),
        (5,1),(5,1),(4,1),(4,1),(3,1),(3,1),(2,2),
        # 1 1 5 5 6 6 5 - | 4 4 3 3 2 2 1 -
        (1,1),(1,1),(5,1),(5,1),(6,1),(6,1),(5,2),
        (4,1),(4,1),(3,1),(3,1),(2,1),(2,1),(1,2),
    ]),

    # ---- 3. 欢乐颂 (C4 八度, 4/4) ----
    # 3 3 4 5 | 5 4 3 2 | 1 1 2 3 | 3. 2 2 -
    ("欢乐颂", 4, [
        (3,1),(3,1),(4,1),(5,1),
        (5,1),(4,1),(3,1),(2,1),
        (1,1),(1,1),(2,1),(3,1),
        (3,1.5),(2,0.5),(2,2),
        # 3 3 4 5 | 5 4 3 2 | 1 1 2 3 | 2. 1 1 -
        (3,1),(3,1),(4,1),(5,1),
        (5,1),(4,1),(3,1),(2,1),
        (1,1),(1,1),(2,1),(3,1),
        (2,1.5),(1,0.5),(1,2),
        # 2 2 3 1 | 2 3(4) 3 1 | 2 3(4) 3 2 | 1 2 (5低) 5(低) -
        (2,1),(2,1),(3,1),(1,1),
        (2,1),(3,1),(4,1),(3,1),(1,1),
        (2,1),(3,1),(4,1),(3,1),(2,1),
        (1,1),(2,1),(5,1),(5,2),
        # 3 3 4 5 | 5 4 3 2 | 1 1 2 3 | 2. 1 1 -
        (3,1),(3,1),(4,1),(5,1),
        (5,1),(4,1),(3,1),(2,1),
        (1,1),(1,1),(2,1),(3,1),
        (2,1.5),(1,0.5),(1,2),
    ]),

    # ---- 4. 生日快乐 (混合八度, 3/4) ----
    # 5 5 6 5 1' 7 | 5 5 6 5 2' 1' | 5 5 5'' 3' 1' 7 | 6 6 3' 1' 2' 1'
    # 用 octave=4, 个别音用 (degree, beats, octave_override)
    ("生日快乐", 4, [
        # 5 5 6 5 | 1(高) 7 -
        (5,0.75),(5,0.25),(6,1),(5,1),
        (1,1,(5,)),(7,2),
        # 5 5 6 5 | 2(高) 1(高) -
        (5,0.75),(5,0.25),(6,1),(5,1),
        (2,1,(5,)),(1,1,(5,)),(0,1),
        # 5 5 5(高) 3(高) | 1(高) 7 -
        (5,0.75),(5,0.25),(5,1,(5,)),(3,1,(5,)),
        (1,1,(5,)),(7,2),
        # 6 6 3(高) 1(高) | 2(高) 1(高) -
        (6,0.75),(6,0.25),(3,1,(5,)),(1,1,(5,)),
        (2,1,(5,)),(1,2,(5,)),
    ]),
]


def play_song(psg, name, base_octave, notes, beat_t=0.3):
    """播放一首歌."""
    print(f"\n♪ {name} ♪  (base octave C{base_octave})", flush=True)
    for item in notes:
        if len(item) == 3:
            degree, beats, oct_override = item
            oct_use = oct_override[0]
        else:
            degree, beats = item
            oct_use = base_octave
        if degree == 0:
            # 休止
            psg._sd(BIT_GATE, 0)
            time.sleep(beats * beat_t)
        else:
            f = jianpu_freq(degree, oct_use)
            psg.play_note(f, beats, beat_t)
    time.sleep(0.8)  # 歌间停顿


def main():
    psg = Psg()
    try:
        while True:
            for name, oct, notes in SONGS:
                play_song(psg, name, oct, notes)
            print("\n=== 全部播放完, 重新开始 ===\n")
    except KeyboardInterrupt:
        print("\n停止")
    finally:
        psg.close()
        print("已静音, 设备关闭")

if __name__ == '__main__':
    main()
