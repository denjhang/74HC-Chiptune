#!/usr/bin/env python3
# psg_env_v02.py — PSG v0.2 带软件包络 (每个音 vol 15→0 衰减)
#
# 基于 psg_ft232h_v02.py, 加 note_on_with_env():
#   每个音 = 设频率 + vol 从 15 递减到 0 (软件包络/decay)
#   这才是 PSG 真实用法: 每个音独立有自己的音量包络状态.
#
# 时钟: 64 kHz
# 引脚: C0-C7 数据, D4/D5/D6 = LE/A0/RST (LE 物理接 A0, 同一根线)

import ftd2xx
import time

# ============== PSG 硬件控制 (同 psg_ft232h_v02) ==============
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
def note_on_env(psg, freq, step_t=0.06):
    """触发一个音: 设频率, 音量从 15 衰减到 0 (每档 step_t 秒).
    这是 PSG 真实用法 — 每个音独立有自己的包络状态."""
    actual = psg.freq(freq)
    for vol in range(15, -1, -1):     # 15, 14, 13, ... 1, 0
        psg.volume(vol)
        time.sleep(step_t)
    return actual


# ===================== 测试主程序 =====================
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
        print(f"=== PSG v0.2 软件包络测试 (CLK={CLK_HZ}Hz) ===")
        print("    每音 vol 15→0 衰减 (每档 0.06s), 无限循环, Ctrl+C 停")
        lap = 0
        while True:
            lap += 1
            print(f"\n########## 第 {lap} 轮 ##########")
            for name, f in SCALE:
                actual = note_on_env(psg, f, step_t=0.06)
                print(f"  {name} {f}Hz -> {actual:.1f}Hz  [vol 15→0]", flush=True)
                time.sleep(0.05)   # 音间小间隔
    except KeyboardInterrupt:
        print("\n停止")
    finally:
        psg.close()
        print("已静音, 设备关闭")
