#!/usr/bin/env python3
# psg_voltest_v03.py — PSG2 v0.3 方波通道音量/频率测试 (极简, 无 ADSR)
#
# 用途: 排查音量包络是否生效. 直接手动控制 period + 音量, 不经过 ADSR/颤音.
# 控制 (中断式键盘):
#   ←/→  = 频率下/上 (period +1/-1, 直接写硬件)
#   ↑/↓  = 音量 +1/-1 (0-15)
#   D    = 占空比循环 (与 psg_adsr_songs_v03.py 一致)
#   S    = 方波/白噪 (bit7 mode)
#   W    = REF 切换 占空比变体↔Q0 (bit6 ref)
#   1-8  = 快速选音域 (C3..C7 对应 1-5, 直接跳 period)
#   q/ESC = 退出
#
# 与 psg_adsr_songs_v03.py 共享控制字编码 (bit6=ref/bit7=mode, 硬件实测对调).

import ftd2xx
import time
import threading
import sys
import os

try:
    import msvcrt
except ImportError:
    msvcrt = None

# ============== PSG 硬件控制 (与 psg_adsr_songs_v03.py 一致) ==============
BIT_LE, BIT_A0, BIT_RST = 4, 5, 6
CLK_HZ = 64000

DUTY_LIST = [
    (0b00, '12.5%', 2),
    (0b01, '25%',    1),
    (0b10, '6.25%',  3),
    (0b11, '50%',    0),
]


class Psg:
    def __init__(self):
        self.dev = ftd2xx.open(0)
        self.dev.resetDevice()
        self.dev.setBitMode(0x00, 0x02)
        time.sleep(0.05)
        self._d = 0; self._c = 0
        self._vol = 0
        # 音色状态 (bit 位据硬件实测: bit6=ref, bit7=mode)
        self.duty = 0b11   # 默认 50% (无补偿)
        self.mode = 0
        self.ref  = 0
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

    def write_ctrl(self, vol):
        """写方波控制字: 音量(bit0-3) | 占空比(bit4-5) | ref(bit6) | mode(bit7)."""
        vol = max(0, min(15, vol))
        self._vol = vol
        self._sd(BIT_LE, 0)
        self._c = ((vol & 0x0F)
                   | ((self.duty & 0x03) << 4)
                   | ((self.ref & 1) << 6)
                   | ((self.mode & 1) << 7))
        self.dev.write(bytes([0x82, self._c, 0xFF]))
        self._sd(BIT_A0, 1); self._sd(BIT_A0, 0)

    def set_period(self, p):
        """写 period 寄存器 (HC373, LE 上升沿)."""
        p = max(0, min(255, int(p)))
        self._sd(BIT_A0, 0)
        self._c = p & 0xFF
        self.dev.write(bytes([0x82, self._c, 0xFF]))
        self._sd(BIT_LE, 1); self._sd(BIT_LE, 0)

    def close(self):
        try:
            self.write_ctrl(0)
            self._d = 0; self._c = 0; self._wb()
        except: pass
        self.dev.close()


# ============== 频率 ↔ period 换算 (与主程序一致) ==============
def freq_to_period(f):
    return max(1, min(255, round(256 - CLK_HZ / (2 * f))))

def period_to_freq(p):
    d = 256 - p
    return CLK_HZ / (2 * d) if d > 0 else 0.0

# 快速选音域: 键 1-5 → C3-C7
NOTE_PRESETS = {
    '1': ('C3', 131),   # period = 256 - 64000/262 = 256-244 = 12
    '2': ('C4', 262),
    '3': ('C5', 523),
    '4': ('C6', 1047),
    '5': ('C7', 2093),
}


def status_line(psg, period):
    freq = period_to_freq(period)
    duty_name = next(n for (c, n, _o) in DUTY_LIST if c == psg.duty)
    mode_name = '白噪' if psg.mode else '方波'
    ref_name  = 'Q0调制' if psg.ref else '占空比变体'
    print(f"\r  period={period:3d} freq={freq:6.1f}Hz vol={psg._vol:2d}/15  "
          f"占空比={duty_name:7s} mode={mode_name} REF={ref_name}      ", end='', flush=True)


def main():
    psg = Psg()
    duty_idx = 3   # 默认 50% (DUTY_LIST 索引)
    psg.duty = DUTY_LIST[duty_idx][0]

    period = freq_to_period(440)   # 起始 A4
    vol = 8                        # 起始音量

    # 初始写入
    psg.set_period(period)
    psg.write_ctrl(vol)

    print("=== PSG2 v0.3 音量/频率测试 (无 ADSR) ===")
    print("  ←/→ 频率下/上 (period ±1)")
    print("  ↑/↓  音量 ±1 (0-15)")
    print("  D 占空比循环 | S 方波/白噪 | W REF切换")
    print("  1-5 快速选音域 C3-C7 | T 音量扫描(0→15) | q/ESC 退出")
    print()
    status_line(psg, period)
    print()  # 换行, 让键盘操作不覆盖

    stop = False
    while not stop:
        if msvcrt and msvcrt.kbhit():
            ch = msvcrt.getch()
            # 方向键: Windows getch 返回 \xe0 前缀 + 第二字节
            if ch == b'\xe0':
                ch2 = msvcrt.getch()
                if ch2 == b'M':     # →
                    period = max(1, period - 1)
                    psg.set_period(period)
                elif ch2 == b'K':   # ←
                    period = min(255, period + 1)
                    psg.set_period(period)
                elif ch2 == b'H':   # ↑
                    vol = min(15, vol + 1)
                    psg.write_ctrl(vol)
                elif ch2 == b'P':   # ↓
                    vol = max(0, vol - 1)
                    psg.write_ctrl(vol)
            elif ch in (b'd', b'D'):
                duty_idx = (duty_idx + 1) % len(DUTY_LIST)
                psg.duty = DUTY_LIST[duty_idx][0]
                psg.write_ctrl(vol)   # 刷新控制字 (带新占空比)
            elif ch in (b's', b'S'):
                psg.mode ^= 1
                psg.write_ctrl(vol)
            elif ch in (b'w', b'W'):
                psg.ref ^= 1
                psg.write_ctrl(vol)
            elif ch in NOTE_PRESETS:
                name, freq = NOTE_PRESETS[ch]
                period = freq_to_period(freq)
                psg.set_period(period)
                print(f"\n  >>> 跳到 {name} ({freq}Hz, period={period})", flush=True)
            elif ch in (b't', b'T'):
                # 音量扫描测试: vol 0→15, 每档停 0.8s, 打印 C口字节
                print("\n  === 音量扫描 vol 0→15 (每档 0.8s) ===", flush=True)
                for v in range(16):
                    psg.write_ctrl(v)
                    c = psg._c
                    d_val = (v & 0x0F) << 4   # TLC7524 的 D 值 (DB4-7 = vol)
                    print(f"    vol={v:2d}  C口=0x{c:02X} (bit3={((c>>3)&1)} bit2={((c>>2)&1)} bit1={((c>>1)&1)} bit0={(c&1)})  "
                          f"D={d_val:3d}/255  幅度={d_val/255*100:4.1f}%", flush=True)
                    time.sleep(0.8)
                vol = 8
                psg.write_ctrl(vol)
                print("  === 扫描结束, 回到 vol=8 ===", flush=True)
            elif ch in (b'q', b'Q', b'\x1b'):
                stop = True
            status_line(psg, period)
        time.sleep(0.02)

    print("\n退出")
    psg.write_ctrl(0)
    psg._sd(BIT_RST, 0)
    psg.close()
    print("已静音, 设备关闭")


if __name__ == '__main__':
    main()
