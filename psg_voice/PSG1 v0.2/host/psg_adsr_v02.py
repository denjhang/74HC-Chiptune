#!/usr/bin/env python3
# psg_adsr_v02.py — PSG v0.2 钢琴风格 ADSR 包络合成器
#
# 架构: 上位机维护包络状态机, 时间驱动循环 (TICK=5ms 推进一次).
#   每个 tick 根据 ADSR 状态计算当前 vol, 写入 TLC7524.
#   音长 (keyon 持续) 只影响 Sustain 段多长, 不影响 A/D/R 形状.
#   keyon 触发 A→D→S, keyoff 触发 R→0.
#
# 钢琴包络特征: 起音快 (几ms到顶), 衰减中 (满→延音), 延音保持, 释放快.
#
# 时钟: 64 kHz
# 引脚: C0-C7 数据, D4/D5/D6 = LE/A0/RST

import ftd2xx
import time

# ============== PSG 硬件控制 ==============
BIT_LE, BIT_A0, BIT_RST = 4, 5, 6
CLK_HZ = 64000


class Psg:
    def __init__(self):
        self.dev = ftd2xx.open(0)
        self.dev.resetDevice()
        self.dev.setBitMode(0x00, 0x02)
        time.sleep(0.05)
        self._d = 0; self._c = 0
        self._vol = 0
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
        self.dev.write(bytes([0x82, self._c, 0xFF]))
        self._sd(BIT_A0, 1); self._sd(BIT_A0, 0)

    def freq(self, f):
        if f <= 0:
            return 0.0
        p = max(1, min(255, round(256 - CLK_HZ / (2 * f))))
        self._sd(BIT_A0, 0)
        self._c = p & 0xFF
        self.dev.write(bytes([0x82, self._c, 0xFF]))
        self._sd(BIT_LE, 1); self._sd(BIT_LE, 0)
        return CLK_HZ / (2 * (256 - p))

    def close(self):
        try:
            self.volume(0)
            self._d = 0; self._c = 0; self._wb()
        except: pass
        self.dev.close()


# ============== ADSR 包络状态机 ==============
TICK = 0.005   # 状态机推进步长 5ms (音量更新粒度)

# 包络形状 (钢琴: 快起音, 明显衰减, 低延音, 快释放)
# 时间单位是 tick 数 (1 tick = 5ms)
A_TICKS = 2     # Attack: 10ms 瞬间到顶 (0→15)
D_TICKS = 60    # Decay:  300ms 明显衰减到延音 (15→S)
S_LEVEL = 4     # Sustain 电平 (较低, 突出衰减落差)
R_TICKS = 6     # Release: 30ms 快释放 (当前→0)

# 状态
ENV_IDLE = 0
ENV_ATTACK = 1
ENV_DECAY = 2
ENV_SUSTAIN = 3
ENV_RELEASE = 4


class Voice:
    """单声部 ADSR 包络状态机."""
    def __init__(self, psg):
        self.psg = psg
        self.state = ENV_IDLE
        self.vol = 0          # 当前音量 (0-15)
        self.tick_cnt = 0     # 当前段已过的 tick
        self.rel_start = 0    # release 起始音量
        self.cur_freq = 0

    def key_on(self, freq):
        """触发一个音: 起音 (A段). 频率立即设定, 音量从当前进入 Attack."""
        if freq > 0:
            self.cur_freq = freq
            self.psg.freq(freq)
        self.state = ENV_ATTACK
        self.tick_cnt = 0
        # Attack 从当前音量开始 (若 release 中 retrigger, 从当前往上)

    def key_off(self):
        """释放: 进入 R 段, 从当前音量快速降到 0."""
        if self.state != ENV_IDLE:
            self.state = ENV_RELEASE
            self.tick_cnt = 0
            self.rel_start = self.vol

    def tick(self):
        """推进一个 tick (5ms), 更新音量并写入 DAC."""
        if self.state == ENV_ATTACK:
            self.tick_cnt += 1
            # 线性 0→15 在 A_TICKS 内
            self.vol = min(15, round(15 * self.tick_cnt / A_TICKS))
            if self.tick_cnt >= A_TICKS:
                self.vol = 15
                self.state = ENV_DECAY
                self.tick_cnt = 0
        elif self.state == ENV_DECAY:
            self.tick_cnt += 1
            # 线性 15→S_LEVEL 在 D_TICKS 内
            self.vol = max(S_LEVEL, round(15 - (15 - S_LEVEL) * self.tick_cnt / D_TICKS))
            if self.tick_cnt >= D_TICKS:
                self.vol = S_LEVEL
                self.state = ENV_SUSTAIN
        elif self.state == ENV_SUSTAIN:
            self.vol = S_LEVEL   # 保持
        elif self.state == ENV_RELEASE:
            self.tick_cnt += 1
            # 线性 rel_start→0 在 R_TICKS 内
            self.vol = max(0, round(self.rel_start * (1 - self.tick_cnt / R_TICKS)))
            if self.tick_cnt >= R_TICKS:
                self.vol = 0
                self.state = ENV_IDLE
        # IDLE: vol=0, 不写
        if self.state != ENV_IDLE or self.vol != 0:
            self.psg.volume(self.vol)


# ============== 简谱 -> 频率 ==============
NOTE_SEMITONE = {1:0, 2:2, 3:4, 4:5, 5:7, 6:9, 7:11}

def jianpu_freq(degree, octave):
    midi = 12 * (octave + 1) + NOTE_SEMITONE[degree]
    return 440.0 * (2 ** ((midi - 69) / 12.0))


# ============== 歌曲数据 (简谱) ==============
SONGS = [
    ("两只老虎", 4, [
        (1,1),(2,1),(3,1),(1,1), (1,1),(2,1),(3,1),(1,1),
        (3,1),(4,1),(5,2),       (3,1),(4,1),(5,2),
        (5,0.5),(6,0.5),(5,0.5),(4,0.5),(3,1),(1,1),
        (5,0.5),(6,0.5),(5,0.5),(4,0.5),(3,1),(1,1),
        (1,1),(1,1),(1,2),
    ]),
    ("小星星", 4, [
        (1,1),(1,1),(5,1),(5,1),(6,1),(6,1),(5,2),
        (4,1),(4,1),(3,1),(3,1),(2,1),(2,1),(1,2),
        (5,1),(5,1),(4,1),(4,1),(3,1),(3,1),(2,2),
        (5,1),(5,1),(4,1),(4,1),(3,1),(3,1),(2,2),
        (1,1),(1,1),(5,1),(5,1),(6,1),(6,1),(5,2),
        (4,1),(4,1),(3,1),(3,1),(2,1),(2,1),(1,2),
    ]),
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


def play_song(psg, voice, name, base_octave, notes, beat_t=0.22):
    """播放一首歌. 音长 = 拍数 × beat_t (只影响 Sustain 段时长)."""
    print(f"\n♪ {name} ♪  (beat_t={beat_t}s, ADSR: A{A_TICKS*TICK*1000:.0f}ms "
          f"D{D_TICKS*TICK*1000:.0f}ms S={S_LEVEL} R{R_TICKS*TICK*1000:.0f}ms)", flush=True)
    for item in notes:
        if len(item) == 3:
            degree, beats, oct_override = item
            oct_use = oct_override[0]
        else:
            degree, beats = item
            oct_use = base_octave

        dur = beats * beat_t   # 这个音的持续时长 (keyon 时长)

        if degree == 0:
            # 休止: keyoff + 等待
            voice.key_off()
            n_ticks = int(dur / TICK)
            for _ in range(n_ticks):
                voice.tick()
                time.sleep(TICK)
        else:
            f = jianpu_freq(degree, oct_use)
            voice.key_on(f)
            # keyon 持续 dur 秒 (在 Sustain 段), 期间推进 tick
            n_ticks = int(dur / TICK)
            for _ in range(n_ticks):
                voice.tick()
                time.sleep(TICK)
            voice.key_off()
            # Release 段
            for _ in range(R_TICKS + 2):
                voice.tick()
                time.sleep(TICK)
    time.sleep(0.4)


def main():
    psg = Psg()
    voice = Voice(psg)
    try:
        while True:
            for name, oct, notes in SONGS:
                play_song(psg, voice, name, oct, notes)
            print("\n=== 全部播放完, 重新开始 ===\n")
    except KeyboardInterrupt:
        print("\n停止")
    finally:
        psg.close()
        print("已静音, 设备关闭")

if __name__ == '__main__':
    main()
