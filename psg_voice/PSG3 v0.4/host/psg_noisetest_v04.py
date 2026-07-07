#!/usr/bin/env python3
# psg_noisetest_v04.py — PSG3 v0.4 噪音通道 (CH1) 测试
#
# v0.4 = PSG2 v0.3 rev.a 噪音通道挂 YM2413 风格复用总线 (PSG3 v0.4 接口层).
# 通道逻辑照搬 v0.3 rev.a, 只改底层驱动为两拍写.
#
# YM2413 两拍写协议:
#   /CS=0 → bus=地址(独热码), A0=0, /WR↓→↑ → 锁地址
#         → bus=数据, A0=1, /WR↓→↑ → 锁数据 → /CS=1
#
# 寄存器映射 (独热码地址):
#   reg0 (0x01): CH0 period (方波频率, 绑定模式时噪音跟 TC 走)
#   reg2 (0x04): 噪音控制 (音量 bit0-3 / 频率挡 bit4-5 / 绑定 bit6)
#
# FT232H 接线 (物理同 v0.3, 语义变): C0-C7=数据总线, D4=A0, D5=/WR, D6=/RST, D7=/CS
#
# 噪音控制字 (reg2):
#   bit0-3: 音量 (Q0-Q3 → TLC7524 DB4-7)
#   bit4-5: 频率挡 (00=÷2 / 01=÷4 / 10=÷8 / 11=÷16, 仅独立模式)
#   bit6:   绑定开关 (0=独立分频 / 1=直通 square_tc)
#   bit7:   预留
#
# 键盘:
#   ↑/↓    = 音量 ±1 (0-15)
#   ←/→    = 独立模式: 噪音频率挡循环 (÷2/÷4/÷8/÷16)
#            绑定模式: 方波 period ±1 (音高↓/↑, 噪音跟 TC 走)
#   B      = 绑定开关 toggle (独立 ↔ 绑定)
#   0/空格 = 静音
#   q/ESC  = 退出

import ftd2xx
import time
import sys
import os

try:
    import msvcrt
except ImportError:
    msvcrt = None

# ============== FT232H 控制 (YM2413 总线, D 口控制位) ==============
BIT_A0, BIT_WR, BIT_RST, BIT_CS = 4, 5, 6, 7
CLK_HZ = 64000

# 噪音频率挡 (bit4-5 编码 → 分频比 + 标签)
NOISE_FREQ_LIST = [
    (0b00, '÷2  (32kHz 最高频白噪)'),
    (0b01, '÷4  (16kHz)'),
    (0b10, '÷8  (8kHz)'),
    (0b11, '÷16 (4kHz 低频杂音)'),
]


class NoisePsg:
    """同时控制方波通道 (写 period 供 TC) + 噪音通道, 走 YM2413 两拍写."""
    def __init__(self):
        self.dev = ftd2xx.open(0)
        self.dev.resetDevice()
        self.dev.setBitMode(0x00, 0x02)
        # setBitMode 后: /CS=1 (事务外, 锁存全无效), /WR=1, /RST=1, A0=0
        self._d = 0xFF
        self.dev.write(bytes([0x80, self._d, 0xFF]))   # 方向全输出
        self._d = (1 << BIT_WR) | (1 << BIT_RST) | (1 << BIT_CS)   # A0=0
        self._c = 0
        self.dev.write(bytes([0x80, self._d, 0xFF]))
        time.sleep(0.05)
        self._vol = 0
        self.reset()

    def _wb(self):
        self.dev.write(bytes([0x80, self._d & 0xFF, 0xFF]))
        self.dev.write(bytes([0x82, self._c & 0xFF, 0xFF]))
        time.sleep(2e-3)

    def _sd(self, bit, v):
        """D 口位操作 (零星用: reset/close)."""
        if v: self._d |= (1 << bit)
        else: self._d &= ~(1 << bit)
        self.dev.write(bytes([0x80, self._d & 0xFF, 0xFF]))
        time.sleep(2e-3)

    @staticmethod
    def _cmd_d(d_val):
        return bytes([0x80, d_val & 0xFF, 0xFF])

    @staticmethod
    def _cmd_c(c_val):
        return bytes([0x82, c_val & 0xFF, 0xFF])

    def _bus_write(self, addr, data):
        """YM2413 两拍写, MPSSE 批量打包一次发送.
        ⚠️ A0/CS 跳变必须在 WR=0 期间 (避免 data_strobe/addr_cp 误上升沿).
        addr_cp=cs&a0_n&wr, data_strobe=cs&A0&wr — 任何 0→1 跳变都锁存.
        所以: WR=0 → 切 A0/CS → WR=1 (唯一锁存上升沿)."""
        M_A0, M_WR, M_RST, M_CS = 1<<BIT_A0, 1<<BIT_WR, 1<<BIT_RST, 1<<BIT_CS
        RST = M_RST
        buf = bytearray()
        # 事务开始: WR=0 → CS=0 (CS 跳变在 WR=0 期间)
        buf += self._cmd_d(RST)                                  # WR=0
        buf += self._cmd_d(RST)                                  # CS=0 (addr_cp=cs&1&0=0 安全)
        # 第 1 拍写地址
        buf += self._cmd_c(addr)                                 # C 口=地址
        buf += self._cmd_d(RST)                                  # A0=0 稳定 (WR=0)
        buf += self._cmd_d(RST | M_WR)                          # WR↑: addr_cp 上升沿 → 锁地址
        # 第 2 拍写数据: WR=0 → A0=1 (A0 跳变在 WR=0 期间)
        buf += self._cmd_d(RST)                                  # WR=0
        buf += self._cmd_c(data)                                 # C 口=数据
        buf += self._cmd_d(RST | M_A0)                          # A0=1 (WR=0, data_strobe=0 安全)
        buf += self._cmd_d(RST | M_A0 | M_WR)                  # WR↑: data_strobe 上升沿 → 锁数据
        # 事务结束: WR=0 → CS=1,A0=1 → A0=0,WR=1 (CS 跳变在 WR=0 期间)
        buf += self._cmd_d(RST | M_A0)                          # WR=0
        buf += self._cmd_d(RST | M_CS | M_A0)                  # CS=1 (WR=0 安全)
        buf += self._cmd_d(RST | M_CS | M_WR)                  # A0=0, WR=1 (空闲态)
        self.dev.write(bytes(buf))
        self._d = RST | M_CS | M_WR

    def reset(self):
        self._sd(BIT_RST, 0); time.sleep(2e-3)
        self._sd(BIT_RST, 1); time.sleep(2e-3)

    def write_noise_ctrl(self, vol, freq_code, bind):
        """写噪音控制字到 reg2 (独热码 0x04):
           音量(bit0-3) | 频率挡(bit4-5) | 绑定(bit6)."""
        vol = max(0, min(15, vol))
        self._vol = vol
        ctrl = ((vol & 0x0F)
                | ((freq_code & 0x03) << 4)
                | ((bind & 1) << 6))
        self._bus_write(0x04, ctrl)

    def write_square_period(self, period):
        """写方波 period 到 reg0 (独热码 0x01). 绑定模式噪音跟方波 TC 走."""
        period = max(0, min(255, int(period)))
        self._bus_write(0x01, period)

    def silence(self):
        self.write_noise_ctrl(0, 0b00, 0)
        self.write_square_period(255)

    def close(self):
        try:
            self.silence()
            self._d = (1 << BIT_CS)   # CS=1 (禁止锁存), RST=0 (按住计数器)
            self._c = 0
            self._wb()
            time.sleep(0.02)
        except: pass
        self.dev.close()


def freq_to_period(f):
    return max(1, min(255, round(256 - CLK_HZ / (2 * f))))


def status_line(psg, vol, freq_idx, bind, square_period):
    freq_name = NOISE_FREQ_LIST[freq_idx][1]
    mode = '绑定 (跟方波 TC)' if bind else '独立分频'
    sq_info = ''
    if bind:
        d = 256 - square_period
        sq_freq = CLK_HZ / (2 * d) if d > 0 else 0
        sq_info = f'  方波={sq_freq:.0f}Hz (period={square_period})'
    print(f"\r  vol={vol:2d}/15  频率挡={freq_name:24s}  mode={mode}{sq_info}      ", end='', flush=True)


def main():
    psg = NoisePsg()
    vol = 8
    freq_idx = 0   # NOISE_FREQ_LIST 索引
    bind = 0
    square_period = freq_to_period(262)   # 默认 C4

    # 初始化: 方波 period + 噪音控制
    psg.write_square_period(square_period)
    psg.write_noise_ctrl(vol, NOISE_FREQ_LIST[freq_idx][0], bind)

    print("=== PSG3 v0.4 噪音通道 (CH1) 测试 ===")
    print("  ↑/↓ 音量 ±1")
    print("  ←/→ 独立: 噪音频率挡循环 (÷2/÷4/÷8/÷16) | 绑定: 方波音高 ±1")
    print("  B 绑定开关 toggle")
    print("  0/空格 静音 | q/ESC 退出")
    print()
    status_line(psg, vol, freq_idx, bind, square_period)
    print()

    stop = False
    while not stop:
        if msvcrt and msvcrt.kbhit():
            ch = msvcrt.getch()
            if ch == b'\xe0':
                ch2 = msvcrt.getch()
                if ch2 == b'H':     # ↑
                    vol = min(15, vol + 1)
                    psg.write_noise_ctrl(vol, NOISE_FREQ_LIST[freq_idx][0], bind)
                elif ch2 == b'P':   # ↓
                    vol = max(0, vol - 1)
                    psg.write_noise_ctrl(vol, NOISE_FREQ_LIST[freq_idx][0], bind)
                elif ch2 == b'M':   # →
                    if bind:
                        # 绑定模式: 调方波 period (音高↑, 噪音跟 TC 走)
                        square_period = max(1, square_period - 1)
                        psg.write_square_period(square_period)
                    else:
                        # 独立模式: 切噪音频率挡
                        freq_idx = (freq_idx + 1) % len(NOISE_FREQ_LIST)
                        psg.write_noise_ctrl(vol, NOISE_FREQ_LIST[freq_idx][0], bind)
                elif ch2 == b'K':   # ←
                    if bind:
                        square_period = min(255, square_period + 1)
                        psg.write_square_period(square_period)
                    else:
                        freq_idx = (freq_idx - 1) % len(NOISE_FREQ_LIST)
                        psg.write_noise_ctrl(vol, NOISE_FREQ_LIST[freq_idx][0], bind)
            elif ch in (b'b', b'B'):
                bind ^= 1
                psg.write_noise_ctrl(vol, NOISE_FREQ_LIST[freq_idx][0], bind)
            elif ch in (b'q', b'Q', b'\x1b'):
                stop = True
            elif ch == b' ' or ch == b'0':   # 空格/0 静音
                psg.silence()
                vol = 0
            status_line(psg, vol, freq_idx, bind, square_period)
        time.sleep(0.02)

    print("\n退出")
    psg.close()
    print("已静音, 设备关闭")


if __name__ == '__main__':
    main()
