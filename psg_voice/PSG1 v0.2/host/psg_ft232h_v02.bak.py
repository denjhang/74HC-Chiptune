#!/usr/bin/env python3
# psg_ft232h_v02.py — FT232H 控制 PSG v0.2 (单通道方波 + 4-bit 音量)
#
# 基于 v0.1 最新的 play_songs.py 风格改写, 相对改动:
#   1. D5 从 GATE 改成 A0 (写音量选通, HC374 CP 上升沿)
#   2. 新增 set_volume(0-15): C 口低 4 位放 vol, A0 上升沿锁存到 HC374
#   3. 去掉 GATE: vol=0 即静音 (TLC7524 D=0 输出 0)
#   4. period 和音量共用 C0-C7: 写 period 后 C 口残留值, 写音量前必须重设 C 口低 4 位
#
# 时钟: 64 kHz (与 v0.1 实测一致, handoff.md 记录的甜点)
# 引脚: C0-C7 数据, D4/D5/D6 = LE/A0/RST
#
# 音量映射: vol(0-15) -> HC374 锁存 -> TLC7524 DB4-DB7
#          D = vol << 4 (0-240), 输出幅度 = 5V * D/256
#          vol=0 静音, vol=15 满音量(4.69V)

import ftd2xx
import time

# ============== PSG 硬件控制 ==============
BIT_LE, BIT_A0, BIT_RST = 4, 5, 6   # v0.1: BIT_GATE(5) -> BIT_A0
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

    # ---- 音量 (v0.2 新增, 与 freq 完全隔离) ----
    def volume(self, vol):
        """写音量: C 口低 4 位放 vol(0-15), A0(D5) 上升沿锁存到 HC374.
        操作前先把 LE 拉到无效(低), 确保 period 锁存器不跟随 C 口变化."""
        vol = max(0, min(15, vol))
        self._vol = vol
        # 1. LE 必须无效 (低), 隔离 period 锁存器
        self._sd(BIT_LE, 0)
        # 2. C 口低 4 位 = vol, 高 4 位清 0
        self._c = vol & 0x0F
        self.dev.write(bytes([0x82, self._c, 0xFF])); time.sleep(2e-3)
        # 3. A0 上升沿 -> HC374 锁存音量
        self._sd(BIT_A0, 1); self._sd(BIT_A0, 0)

    # ---- period / 频率 (与 volume 完全隔离) ----
    def freq(self, f):
        """写 period: C 口放 8 位 + D4 LE 脉冲 (高透明/低锁存).
        操作前先把 A0 拉到无效(低), 确保音量不被 period 数据污染."""
        if f <= 0:
            return 0.0
        p = max(1, min(255, round(256 - CLK_HZ / (2 * f))))
        # 1. A0 必须无效 (低), 隔离 HC374
        self._sd(BIT_A0, 0)
        # 2. C 口 = period 8 位
        self._c = p & 0xFF
        self.dev.write(bytes([0x82, self._c, 0xFF])); time.sleep(2e-3)
        # 3. LE 高 (透明) 让 period 进入, 再 LE 低 (锁存)
        self._sd(BIT_LE, 1); self._sd(BIT_LE, 0)
        return CLK_HZ / (2 * (256 - p))

    # ---- 高层封装 ----
    def play_note(self, f, beats, beat_t, vol=None):
        """响一个音: beats 拍. vol=None 用当前音量, 否则临时设定."""
        if f > 0:
            self.freq(f)
            if vol is not None:
                self.volume(vol)
        time.sleep(beats * beat_t)
        self.volume(0)             # vol=0 静音 (替代 v0.1 的 GATE=0)
        time.sleep(0.02)

    def close(self):
        try:
            self.volume(0)
            self._d = 0; self._c = 0; self._wb()
        except: pass
        self.dev.close()


# ============== 简谱 -> 频率 (沿用 play_songs.py) ==============
NOTE_SEMITONE = {1:0, 2:2, 3:4, 4:5, 5:7, 6:9, 7:11}

def jianpu_freq(degree, octave):
    midi = 12 * (octave + 1) + NOTE_SEMITONE[degree]
    return 440.0 * (2 ** ((midi - 69) / 12.0))


# ===================== 测试主程序 (无限循环, 供硬件观测) =====================
# 运行方式: python psg_ft232h_v02.py
# 行为: C 大调音阶, 每音满音量响 0.5s 后静音, 循环不停. Ctrl+C 停.
# 验证点: 听音高变化 (C4->C6), 每音清晰; freq 和 volume 不串扰.
if __name__ == '__main__':
    SCALE = [
        ('C4', 262), ('D4', 294), ('E4', 330), ('F4', 349),
        ('G4', 392), ('A4', 440), ('B4', 494),
        ('C5', 523), ('D5', 587), ('E5', 659), ('F5', 698),
        ('G5', 784), ('A5', 880), ('B5', 988), ('C6', 1047),
    ]

    psg = Psg()
    try:
        psg.reset()
        psg.volume(0)
        print(f"=== PSG v0.2 音阶测试 (CLK={CLK_HZ}Hz) — 无限循环, Ctrl+C 停 ===")
        lap = 0
        while True:
            lap += 1
            print(f"\n########## 第 {lap} 轮 ##########")
            for name, f in SCALE:
                actual = psg.freq(f)        # 设频率
                psg.volume(15)              # 满音量响
                print(f"  {name} {f}Hz -> {actual:.1f}Hz  [响 0.5s]", flush=True)
                time.sleep(0.5)
                psg.volume(0)               # 静音
                time.sleep(0.1)
    except KeyboardInterrupt:
        print("\n停止")
    finally:
        psg.close()
        print("已静音, 设备关闭")
