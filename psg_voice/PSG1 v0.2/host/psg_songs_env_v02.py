#!/usr/bin/env python3
# psg_songs_env_v02.py — PSG v0.2 乐曲播放, 每个音符带软件包络 (vol 15→0)
#
# 基于 v0.1 play_songs.py 的歌曲数据, 改动:
#   - 每个音符触发后, 音量从 15 衰减到 0 (PSG 真实用法)
#   - 衰减总时长 = 拍数 × beat_t (长拍衰减慢, 短拍衰减快)
#   - 休止符直接静音等待
#
# 时钟: 64 kHz
# 引脚: C0-C7 数据, D4/D5/D6 = LE/A0/RST

import ftd2xx
import time

# ============== PSG 硬件控制 (同 psg_env_v02) ==============
BIT_LE, BIT_A0, BIT_RST = 4, 5, 6
CLK_HZ = 64000


class Psg:
    def __init__(self):
        self.dev = ftd2xx.open(0)
        self.dev.resetDevice()
        self.dev.setBitMode(0x00, 0x02)
        time.sleep(0.05)
        self._d = 0; self._c = 0
        self._vol = 15
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

    def volume(self, vol):
        vol = max(0, min(15, vol))
        self._vol = vol
        self._sd(BIT_LE, 0)
        self._c = vol & 0x0F
        self.dev.write(bytes([0x82, self._c, 0xFF])); time.sleep(2e-3)
        self._sd(BIT_A0, 1); self._sd(BIT_A0, 0)

    def freq(self, f):
        if f <= 0:
            return 0.0
        p = max(1, min(255, round(256 - CLK_HZ / (2 * f))))
        self._sd(BIT_A0, 0)
        self._c = p & 0xFF
        self.dev.write(bytes([0x82, self._c, 0xFF])); time.sleep(2e-3)
        self._sd(BIT_LE, 1); self._sd(BIT_LE, 0)
        return CLK_HZ / (2 * (256 - p))

    def close(self):
        try:
            self.volume(0)
            self._d = 0; self._c = 0; self._wb()
        except: pass
        self.dev.close()


# ============== 软件包络 ==============
ENV_STEP = 0.025   # 每档衰减固定时长 (秒), 不随拍数变. 长音才能衰减到 0.

def note_env(psg, freq, total_t):
    """触发一个音: 设频率 + vol 从 15 按固定速度衰减.
    衰减速度固定 (每档 ENV_STEP 秒), total_t 不够则只衰减到中间就被打断.
    只有 total_t >= 16*ENV_STEP 的长音才有机会衰减到 0."""
    if freq <= 0:
        psg.volume(0)
        time.sleep(total_t)
        return 0.0
    actual = psg.freq(freq)
    elapsed = 0.0
    for vol in range(15, -1, -1):    # 15, 14, ... 1, 0
        if elapsed >= total_t:
            break                    # 拍数用完, 被下一个音打断 (停在中间音量)
        psg.volume(vol)
        dt = min(ENV_STEP, total_t - elapsed)
        time.sleep(dt)
        elapsed += dt
    return actual


# ============== 简谱 -> 频率 (沿用 play_songs.py) ==============
NOTE_SEMITONE = {1:0, 2:2, 3:4, 4:5, 5:7, 6:9, 7:11}

def jianpu_freq(degree, octave):
    midi = 12 * (octave + 1) + NOTE_SEMITONE[degree]
    return 440.0 * (2 ** ((midi - 69) / 12.0))


# ============== 歌曲数据 (简谱, 同 v0.1 play_songs.py) ==============
SONGS = [
    # ---- 1. 两只老虎 (C4 八度) ----
    ("两只老虎", 4, [
        (1,1),(2,1),(3,1),(1,1), (1,1),(2,1),(3,1),(1,1),
        (3,1),(4,1),(5,2),       (3,1),(4,1),(5,2),
        (5,0.5),(6,0.5),(5,0.5),(4,0.5),(3,1),(1,1),
        (5,0.5),(6,0.5),(5,0.5),(4,0.5),(3,1),(1,1),
        (1,1),(1,1),(1,2),
    ]),
    # ---- 2. 小星星 (C4 八度) ----
    ("小星星", 4, [
        (1,1),(1,1),(5,1),(5,1),(6,1),(6,1),(5,2),
        (4,1),(4,1),(3,1),(3,1),(2,1),(2,1),(1,2),
        (5,1),(5,1),(4,1),(4,1),(3,1),(3,1),(2,2),
        (5,1),(5,1),(4,1),(4,1),(3,1),(3,1),(2,2),
        (1,1),(1,1),(5,1),(5,1),(6,1),(6,1),(5,2),
        (4,1),(4,1),(3,1),(3,1),(2,1),(2,1),(1,2),
    ]),
    # ---- 3. 欢乐颂 (C4 八度, 4/4) ----
    ("欢乐颂", 4, [
        (3,1),(3,1),(4,1),(5,1),
        (5,1),(4,1),(3,1),(2,1),
        (1,1),(1,1),(2,1),(3,1),
        (3,1.5),(2,0.5),(2,2),
        (3,1),(3,1),(4,1),(5,1),
        (5,1),(4,1),(3,1),(2,1),
        (1,1),(1,1),(2,1),(3,1),
        (2,1.5),(1,0.5),(1,2),
        (2,1),(2,1),(3,1),(1,1),
        (2,1),(3,1),(4,1),(3,1),(1,1),
        (2,1),(3,1),(4,1),(3,1),(2,1),
        (1,1),(2,1),(5,1),(5,2),
        (3,1),(3,1),(4,1),(5,1),
        (5,1),(4,1),(3,1),(2,1),
        (1,1),(1,1),(2,1),(3,1),
        (2,1.5),(1,0.5),(1,2),
    ]),
    # ---- 4. 生日快乐 (混合八度, 3/4) ----
    ("生日快乐", 4, [
        (5,0.75),(5,0.25),(6,1),(5,1),
        (1,1,(5,)),(7,2),
        (5,0.75),(5,0.25),(6,1),(5,1),
        (2,1,(5,)),(1,1,(5,)),(0,1),
        (5,0.75),(5,0.25),(5,1,(5,)),(3,1,(5,)),
        (1,1,(5,)),(7,2),
        (6,0.75),(6,0.25),(3,1,(5,)),(1,1,(5,)),
        (2,1,(5,)),(1,2,(5,)),
    ]),
]


def play_song(psg, name, base_octave, notes, beat_t=0.18):
    """播放一首歌: 每个音的衰减总时长 = 拍数 × beat_t."""
    print(f"\n♪ {name} ♪  (base octave C{base_octave}, beat_t={beat_t}s)", flush=True)
    for item in notes:
        if len(item) == 3:
            degree, beats, oct_override = item
            oct_use = oct_override[0]
        else:
            degree, beats = item
            oct_use = base_octave
        if degree == 0:
            # 休止
            psg.volume(0)
            time.sleep(beats * beat_t)
        else:
            f = jianpu_freq(degree, oct_use)
            actual = note_env(psg, f, beats * beat_t)
    time.sleep(0.5)   # 歌间停顿


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
