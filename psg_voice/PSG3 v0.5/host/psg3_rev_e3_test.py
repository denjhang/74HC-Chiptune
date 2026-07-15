#!/usr/bin/env python3
# psg3_rev_e3_test.py — PSG3 v0.5 rev.e3 PCM 采样通道测试 (无限循环, 频率可调)
#
# rev.e3 = PCM only, 无组合逻辑, 无 toggle. 地址计数器 (U4-U7) 无限循环 0-8191.
# 上电即循环播放 sel 选中的槽, period12 控制回放速率 (= 采样频率).
#
# 寄存器 (独热码):
#   reg3 (0x08): period12[7:0]        ← 步进速率
#   reg4 (0x10): period12[11:8]<<4 | vol[3:0]
#   reg5 (0x20): sel[3:0] (bit3-0), bit7-4 不用
#
# 采样频率 = 4MHz / (8192 × (4096 - period12))
#   period12 越大 → 采样频率越高
#   默认 8kHz: period12 = 4035
#
# FT232H: C0-C7=数据, D4=A0, D5=/WR, D6=/RST, D7=/CS
#
# 键盘:
#   ←/→ = 采样频率 ∓ (粗调, ±1 period12 = 几 Hz)
#   ↑/↓ = 音量 ±1 (0-15)
#   W/E = 下一槽/上一槽 (sel 0-15)
#   A/D = 采样频率 ∓ (细调, ±10 period12)
#   空格 = 静音
#   q/ESC = 退出

import ftd2xx
import time
import sys

try:
    import msvcrt
except ImportError:
    msvcrt = None

BIT_A0, BIT_WR, BIT_RST, BIT_CS = 4, 5, 6, 7
CLK_HZ = 4000000   # 4MHz
STEPS_PCM = 8192   # 每槽 8192 步

# 16 槽名称
SLOT_NAMES = [
    'BD 底鼓', 'SD 军鼓', 'HH 踩镲', 'TOM 嗵鼓',
    'RIM 边击', 'TOP 踩镲开', 'Piano 钢琴', 'SlapBass 贝斯',
    'Oboe 双簧管', 'Trumpet 小号', 'Strings 弦乐', 'Harp 竖琴',
    'Guitar 吉他', 'Shakuhachi 尺八', 'Blow 吹管', 'Oboe2',
]

# 采样频率预设 (Hz → period12)
# period12 = 4096 - 4MHz / (8192 × rate)
RATE_PRESETS = [
    (488,   3095),   # 很慢 (鼓组低频)
    (1000,  3606),   # 1kHz
    (2000,  3850),   # 2kHz
    (4000,  3973),   # 4kHz (降调)
    (8000,  4035),   # 8kHz (标准)
    (16000, 4066),   # 16kHz (升调)
    (32000, 4081),   # 32kHz (很快)
]


class Psg:
    """PSG3 rev.e3 PCM 通道驱动."""
    def __init__(self):
        self.dev = ftd2xx.open(0)
        self.dev.resetDevice()
        self.dev.setBitMode(0x00, 0x02)
        M_A0, M_WR, M_RST, M_CS = 1<<BIT_A0, 1<<BIT_WR, 1<<BIT_RST, 1<<BIT_CS
        self._d = M_WR | M_RST | M_CS
        self.dev.write(bytes([0x80, self._d, 0xFF]))
        self._c = 0
        time.sleep(0.05)
        self.reset()

    @staticmethod
    def _cmd_d(d_val):
        return bytes([0x80, d_val & 0xFF, 0xFF])

    @staticmethod
    def _cmd_c(c_val):
        return bytes([0x82, c_val & 0xFF, 0xFF])

    def _sd(self, bit, v):
        if v: self._d |= (1 << bit)
        else: self._d &= ~(1 << bit)
        self.dev.write(bytes([0x80, self._d & 0xFF, 0xFF]))
        time.sleep(2e-3)

    def _bus_write(self, addr, data):
        """YM2413 两拍写 (完整事务), MPSSE 批量打包.
        ⚠️ A0/CS 跳变必须在 WR=0 期间. 对齐 v0.4."""
        M_A0, M_WR, M_RST, M_CS = 1<<BIT_A0, 1<<BIT_WR, 1<<BIT_RST, 1<<BIT_CS
        RST = M_RST
        buf = bytearray()
        buf += self._cmd_d(RST)                                  # WR=0
        buf += self._cmd_d(RST)                                  # CS=0
        buf += self._cmd_c(addr)                                 # C 口 = 地址
        buf += self._cmd_d(RST)                                  # A0=0 稳定
        buf += self._cmd_d(RST | M_WR)                           # WR↑ 锁地址
        buf += self._cmd_d(RST)                                  # WR=0
        buf += self._cmd_c(data)                                 # C 口 = 数据
        buf += self._cmd_d(RST | M_A0)                           # A0=1
        buf += self._cmd_d(RST | M_A0 | M_WR)                    # WR↑ 锁数据
        buf += self._cmd_d(RST | M_A0)                           # WR=0
        buf += self._cmd_d(RST | M_CS | M_A0)                    # CS=1
        buf += self._cmd_d(RST | M_CS | M_WR)                    # A0=0, WR=1 (空闲)
        self.dev.write(bytes(buf))
        self._d = RST | M_CS | M_WR

    def reset(self):
        self._sd(BIT_RST, 0); time.sleep(2e-3)
        self._sd(BIT_RST, 1); time.sleep(2e-3)

    # 状态跟踪
    _cur_period12 = None
    _cur_vol = None
    _cur_sel = None

    def set_period(self, period12):
        """步进速率变了: 写 reg3 + reg4."""
        period12 = max(0, min(4095, int(period12)))
        if period12 == self._cur_period12:
            return
        self._cur_period12 = period12
        self._bus_write(0x08, period12 & 0xFF)
        v = self._cur_vol if self._cur_vol is not None else 0
        self._bus_write(0x10, (((period12 >> 8) & 0x0F) << 4) | (v & 0x0F))

    def set_vol(self, vol):
        """音量变了: 写 reg4."""
        vol = max(0, min(15, int(vol)))
        if vol == self._cur_vol:
            return
        self._cur_vol = vol
        p = self._cur_period12 if self._cur_period12 is not None else 0
        self._bus_write(0x10, (((p >> 8) & 0x0F) << 4) | (vol & 0x0F))

    def set_sel(self, sel):
        """sel 变了: 写 reg5 (只用低 4 位)."""
        sel = max(0, min(15, int(sel)))
        if sel == self._cur_sel:
            return
        self._cur_sel = sel
        self._bus_write(0x20, sel & 0x0F)

    def init_all(self, period12, vol, sel):
        """启动: 强制写全部 reg."""
        period12 = max(0, min(4095, int(period12)))
        vol = max(0, min(15, int(vol)))
        sel = max(0, min(15, int(sel)))
        self._cur_period12 = period12
        self._cur_vol = vol
        self._cur_sel = sel
        self._bus_write(0x08, period12 & 0xFF)
        self._bus_write(0x10, (((period12 >> 8) & 0x0F) << 4) | (vol & 0x0F))
        self._bus_write(0x20, sel & 0x0F)

    def close(self):
        """退出: vol=0 静音 + 最低频, 再 RST 拉低 + CS 拉高."""
        try:
            self._bus_write(0x08, 0xFF)
            self._bus_write(0x10, ((((0xFFF >> 8) & 0x0F) << 4) | 0))
            self._d = (1 << BIT_CS)
            self._c = 0
            self.dev.write(bytes([0x80, self._d, 0xFF]))
            self.dev.write(bytes([0x82, self._c, 0xFF]))
            time.sleep(0.02)
        except: pass
        self.dev.close()


def period12_to_rate(p12):
    """period12 → 采样频率 (Hz)."""
    if p12 >= 4095:
        return 0
    return CLK_HZ / (STEPS_PCM * (4096 - p12))


def rate_to_period12(rate):
    """采样频率 → period12."""
    if rate <= 0:
        return 0
    return round(4096 - CLK_HZ / (STEPS_PCM * rate))


def slot_name(sel):
    return SLOT_NAMES[sel] if 0 <= sel < len(SLOT_NAMES) else f'sel{sel}'


def status(vol, period12, sel):
    rate = period12_to_rate(period12)
    sn = slot_name(sel)
    print(f"\r  sel={sel:2d}({sn:16s})  period12={period12:4d}  采样频率={rate:8.1f}Hz  vol={vol:2d}/15    ",
          end='', flush=True)


def main():
    psg = Psg()
    vol = 10
    period12 = 4035    # 默认 8kHz
    sel = 6            # 默认 Piano (乐器比鼓组更能听出频率变化)

    # 启动
    psg.init_all(period12, vol, sel)

    print("=== PSG3 v0.5 rev.e3 PCM 采样通道测试 (无限循环) ===")
    print("  ←/→ 采样频率 ∓ (粗调 ±1)")
    print("  A/D 采样频率 ∓ (细调 ±10)")
    print("  ↑/↓ 音量 ±1")
    print("  W/E 下一槽/上一槽 (sel 0-15)")
    print("  1-7 预设频率 (488/1k/2k/4k/8k/16k/32k Hz)")
    print("  空格 静音 | q/ESC 退出")
    print()
    status(vol, period12, sel)
    print()

    stop = False
    last_handle = 0.0
    MIN_INTERVAL = 0.03   # 按键处理最小间隔 30ms (按住连发时节流, 避免 FT232H 缓冲溢出)
    try:
        while not stop:
            if msvcrt and msvcrt.kbhit():
                ch = msvcrt.getch()
                # 排空连发队列: 按住不放时 Windows 连发几十次, 只处理间隔够的
                now = time.time()
                if now - last_handle < MIN_INTERVAL:
                    continue   # 丢弃连发, 等下一轮
                last_handle = now
                if ch == b'\xe0':
                    ch2 = msvcrt.getch()
                    if ch2 == b'H':       # ↑ 音量
                        vol = min(15, vol + 1); psg.set_vol(vol)
                    elif ch2 == b'P':     # ↓ 音量
                        vol = max(0, vol - 1); psg.set_vol(vol)
                    elif ch2 == b'M':     # → 频率+
                        period12 = min(4090, period12 + 1); psg.set_period(period12)
                    elif ch2 == b'K':     # ← 频率-
                        period12 = max(1, period12 - 1); psg.set_period(period12)
                elif ch in (b'd', b'D'):
                    period12 = min(4090, period12 + 10); psg.set_period(period12)
                elif ch in (b'a', b'A'):
                    period12 = max(1, period12 - 10); psg.set_period(period12)
                elif ch in (b'w', b'W'):
                    sel = (sel + 1) % 16; psg.set_sel(sel)
                elif ch in (b'e', b'E'):
                    sel = (sel - 1) % 16; psg.set_sel(sel)
                elif ch == b' ':
                    vol = 0; psg.set_vol(vol)
                elif ch in (b'1', b'2', b'3', b'4', b'5', b'6', b'7'):
                    idx = int(ch) - 1
                    rate, period12 = RATE_PRESETS[idx]
                    psg.set_period(period12)
                elif ch in (b'q', b'Q', b'\x1b'):
                    stop = True
                status(vol, period12, sel)
            time.sleep(0.01)
    except KeyboardInterrupt:
        print("\nCtrl+C 退出")
    finally:
        psg.close()
        print("已静音 (vol=0, freq=最低), 设备关闭")


if __name__ == '__main__':
    main()
