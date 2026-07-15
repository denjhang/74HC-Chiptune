#!/usr/bin/env python3
# psg3_rev_e2_test.py — PSG3 v0.5 rev.e2 双模式波形/采样通道测试
#
# rev.e2 = ROM 查表双模式: 16 种波形 (mode=0) / 16 个 PCM 采样 (mode=1).
# reg5 位定义 (与 rev.d 不同!):
#   bit7    = mode (0=波形, 1=采样)
#   bit6    = trig (1=清地址/触发, 上位机写 1 再写 0)
#   bit5-4  = 预留
#   bit3-0  = sel[3:0] (选 16 波形 / 16 采样)
#
# 寄存器 (独热码):
#   reg3 (0x08): period12[7:0]
#   reg4 (0x10): period12[11:8]<<4 | vol[3:0]
#   reg5 (0x20): mode | trig | 预留 | sel[3:0]
#
# 音高 (波形模式): freq = 4MHz / (256 × (4096 - period12))   (256 步/周期)
# 采样速度 (采样模式): 8192 步/槽, period12 控制回放速率 (默认 8kHz → period12=3596)
#   单次播放到 8191 自动停 (硬件 at_8191 → step=0), 再触发需 trig.
#
# FT232H: C0-C7=数据, D4=A0, D5=/WR, D6=/RST, D7=/CS
#
# 键盘:
#   ←/→ = 音高 ∓1 半音 (波形模式: A0-C8; 采样模式: 变速变调)
#   ↑/↓ = 音量 ±1 (0-15)
#   W/E = 下一槽/上一槽 (sel 0-15)
#   M   = 切模式 (波形 ↔ 采样)
#   T   = 触发 (采样模式: trig 1→0 重新播放; 波形模式: 无效)
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
STEPS_WAVE = 256   # 波形模式 256 步/周期
STEPS_PCM  = 8192  # 采样模式 8192 步/槽
PCM_DEFAULT_HZ = 8000  # 采样默认 8kHz

# reg5 位掩码
M_MODE = 0x80      # bit7
M_TRIG = 0x40      # bit6
# bit5-4 预留
M_SEL  = 0x0F      # bit3-0

# 音名表 (MIDI 21=A0 .. 108=C8)
_NOTE_NAMES = {
    21:'A0',22:'A#0',23:'B0',
    24:'C1',25:'C#1',26:'D1',27:'D#1',28:'E1',29:'F1',30:'F#1',31:'G1',32:'G#1',33:'A1',34:'A#1',35:'B1',
    36:'C2',37:'C#2',38:'D2',39:'D#2',40:'E2',41:'F2',42:'F#2',43:'G2',44:'G#2',45:'A2',46:'A#2',47:'B2',
    48:'C3',49:'C#3',50:'D3',51:'D#3',52:'E3',53:'F3',54:'F#3',55:'G3',56:'G#3',57:'A3',58:'A#3',59:'B3',
    60:'C4',61:'C#4',62:'D4',63:'D#4',64:'E4',65:'F4',66:'F#4',67:'G4',68:'G#4',69:'A4',70:'A#4',71:'B4',
    72:'C5',73:'C#5',74:'D5',75:'D#5',76:'E5',77:'F5',78:'F#5',79:'G5',80:'G#5',81:'A5',82:'A#5',83:'B5',
    84:'C6',85:'C#6',86:'D6',87:'D#6',88:'E6',89:'F6',90:'F#6',91:'G6',92:'G#6',93:'A6',94:'A#6',95:'B6',
    96:'C7',97:'C#7',98:'D7',99:'D#7',100:'E7',101:'F7',102:'F#7',103:'G7',104:'G#7',105:'A7',106:'A#7',107:'B7',
    108:'C8',
}
NOTE_LIST = []
for _midi in range(21, 109):
    _freq = 440.0 * (2.0 ** ((_midi - 69) / 12.0))
    NOTE_LIST.append((_midi, _NOTE_NAMES.get(_midi, f'M{_midi}'), _freq))

# 16 槽名称 (sel 0-15), 两模式共用 sel 编号
# 详见 wiring-table-rev-e2.md 第四节 ROM 分区
SLOT_NAMES = [
    'sine/BD',         'tri/SD',         'saw/HH',         'rsaw/TOM',
    'square50/RIM',    'pulse25/TOP',    'pulse12/Piano',  'wt.sin/SlapBass',
    'wt.halfsin/Oboe', 'wt.abssin/Trumpet','pacman.sine/Strings','pacman.tri/Harp',
    'pacman.saw/Guitar','pacman.step4/Shakuhachi','pulse75/Blow','pulse37/Oboe2',
]


class Psg:
    """PSG3 rev.e2 双模式波形/采样通道驱动."""
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
        ⚠️ A0/CS 跳变必须在 WR=0 期间 (避免 strobe 误上升沿). 对齐 v0.4."""
        M_A0, M_WR, M_RST, M_CS = 1<<BIT_A0, 1<<BIT_WR, 1<<BIT_RST, 1<<BIT_CS
        RST = M_RST
        buf = bytearray()
        buf += self._cmd_d(RST)                                  # WR=0
        buf += self._cmd_d(RST)                                  # CS=0 (WR=0 期间, 安全)
        buf += self._cmd_c(addr)                                 # C 口 = 地址
        buf += self._cmd_d(RST)                                  # A0=0 稳定
        buf += self._cmd_d(RST | M_WR)                           # WR↑ 锁地址
        buf += self._cmd_d(RST)                                  # WR=0
        buf += self._cmd_c(data)                                 # C 口 = 数据
        buf += self._cmd_d(RST | M_A0)                           # A0=1 (WR=0 期间, 安全)
        buf += self._cmd_d(RST | M_A0 | M_WR)                    # WR↑ 锁数据
        buf += self._cmd_d(RST | M_A0)                           # WR=0
        buf += self._cmd_d(RST | M_CS | M_A0)                    # CS=1 (WR=0 期间)
        buf += self._cmd_d(RST | M_CS | M_WR)                    # A0=0, WR=1 (空闲)
        self.dev.write(bytes(buf))
        self._d = RST | M_CS | M_WR

    def reset(self):
        self._sd(BIT_RST, 0); time.sleep(2e-3)
        self._sd(BIT_RST, 1); time.sleep(2e-3)

    # 状态跟踪 (只写变化的 reg, 对齐 v0.4 风格)
    _cur_period12 = None
    _cur_vol = None
    _cur_mode = None
    _cur_sel = None

    def _reg5(self, mode, sel, trig=False):
        """组装并写 reg5 = mode | trig | sel."""
        v = (M_MODE if mode else 0) | (M_TRIG if trig else 0) | (sel & M_SEL)
        self._bus_write(0x20, v)
        return v

    def set_period(self, period12):
        """音高/速率变了: 写 reg3 (period_lo) + reg4 (period_hi | vol)."""
        period12 = max(0, min(4095, int(period12)))
        if period12 == self._cur_period12:
            return
        self._cur_period12 = period12
        self._bus_write(0x08, period12 & 0xFF)
        v = self._cur_vol if self._cur_vol is not None else 0
        self._bus_write(0x10, (((period12 >> 8) & 0x0F) << 4) | (v & 0x0F))

    def set_vol(self, vol):
        """音量变了: 写 reg4 (period_hi | vol)."""
        vol = max(0, min(15, int(vol)))
        if vol == self._cur_vol:
            return
        self._cur_vol = vol
        p = self._cur_period12 if self._cur_period12 is not None else 0
        self._bus_write(0x10, (((p >> 8) & 0x0F) << 4) | (vol & 0x0F))

    def set_sel(self, sel):
        """sel 变了: 写 reg5 (mode 不变, trig=0)."""
        sel = max(0, min(15, int(sel)))
        if sel == self._cur_sel and self._cur_mode is not None:
            return
        self._cur_sel = sel
        self._reg5(self._cur_mode if self._cur_mode is not None else 0, sel, trig=False)

    def set_mode(self, mode):
        """mode 变了: 写 reg5 (sel 不变, trig=0)."""
        if mode == self._cur_mode:
            return
        self._cur_mode = mode
        sel = self._cur_sel if self._cur_sel is not None else 0
        self._reg5(mode, sel, trig=False)

    def trigger(self):
        """触发: 写 trig=1 再写 trig=0 (清地址, 采样模式重新播放).
        波形模式 trig 也写但无实际效果 (硬件 trig_clr = trig AND mode)."""
        sel = self._cur_sel if self._cur_sel is not None else 0
        mode = self._cur_mode if self._cur_mode is not None else 0
        self._reg5(mode, sel, trig=True)     # trig=1 (n_trig_clr=0 → HC161 预置 0)
        time.sleep(2e-3)
        self._reg5(mode, sel, trig=False)    # trig=0 放手 (n_trig_clr=1 → HC161 自由计数)

    def init_all(self, period12, vol, mode, sel):
        """启动: 强制写全部 reg (初始化)."""
        period12 = max(0, min(4095, int(period12)))
        vol = max(0, min(15, int(vol)))
        mode = 1 if mode else 0
        sel = max(0, min(15, int(sel)))
        self._cur_period12 = period12
        self._cur_vol = vol
        self._cur_mode = mode
        self._cur_sel = sel
        self._bus_write(0x08, period12 & 0xFF)
        self._bus_write(0x10, (((period12 >> 8) & 0x0F) << 4) | (vol & 0x0F))
        self._reg5(mode, sel, trig=False)

    def close(self):
        """退出: vol=0 静音 + 最低频, 再 RST 拉低 + CS 拉高 (防冒音, 同 v0.4)."""
        try:
            self._bus_write(0x08, 0xFF)                              # reg3 = 最低频
            self._bus_write(0x10, ((((0xFFF >> 8) & 0x0F) << 4) | 0))  # reg4 = period_hi + vol=0
            self._d = (1 << BIT_CS)       # CS=1 (禁止锁存), RST=0 (按住计数器)
            self._c = 0
            self.dev.write(bytes([0x80, self._d, 0xFF]))
            self.dev.write(bytes([0x82, self._c, 0xFF]))
            time.sleep(0.02)
        except: pass
        self.dev.close()


def freq_to_period12(freq, steps=STEPS_WAVE):
    """freq → period12 (12-bit). freq = CLK / (steps × (4096 - period12))."""
    if freq <= 0:
        return 4095
    p = round(4096 - CLK_HZ / (steps * freq))
    return max(1, min(4095, p))


def pcm_rate_to_period12(rate_hz):
    """采样回放速率 → period12 (8192 步/槽)."""
    return freq_to_period12(rate_hz, steps=STEPS_PCM)


def slot_name(sel):
    return SLOT_NAMES[sel] if 0 <= sel < len(SLOT_NAMES) else f'sel{sel}'


def status(vol, note_idx, mode, sel):
    midi, name, freq = NOTE_LIST[note_idx]
    sn = slot_name(sel)
    md = '采样' if mode else '波形'
    if mode:
        # 采样模式: period12 对应回放速率
        p12 = pcm_rate_to_period12(freq)
        rate = CLK_HZ / (STEPS_PCM * (4096 - p12)) if p12 < 4095 else 0
        print(f"\r  [{md}] sel={sel:2d}({sn:24s}) 音={name:4s}→速率{rate:7.1f}Hz  vol={vol:2d}/15    ",
              end='', flush=True)
    else:
        print(f"\r  [{md}] sel={sel:2d}({sn:24s}) 音={name:4s}({freq:7.2f}Hz)  vol={vol:2d}/15    ",
              end='', flush=True)


def main():
    psg = Psg()
    vol = 10
    note_idx = next(i for i, (m, n, f) in enumerate(NOTE_LIST) if n == 'A4')
    mode = 0       # 默认波形模式
    sel = 0        # 默认 sel=0 (sine / BD)

    def cur_period():
        if mode:
            # 采样模式: 音高键映射到回放速率 (A4=8kHz 基准, 半音±变速)
            return pcm_rate_to_period12(NOTE_LIST[note_idx][2])
        else:
            return freq_to_period12(NOTE_LIST[note_idx][2])

    # 启动: 强制初始化全部 reg
    psg.init_all(cur_period(), vol, mode, sel)

    print("=== PSG3 v0.5 rev.e2 双模式波形/采样通道测试 ===")
    print("  ←/→ 音高 (波形: A0-C8 / 采样: 变速变调)")
    print("  ↑/↓ 音量 ±1")
    print("  W/E 下一槽/上一槽 (sel 0-15)")
    print("  M   切模式 (波形 ↔ 采样)")
    print("  T   触发 (采样模式: 重新播放; 波形模式: 无效)")
    print("  空格 静音 | q/ESC 退出")
    print()
    status(vol, note_idx, mode, sel)
    print()

    stop = False
    try:
        while not stop:
            if msvcrt and msvcrt.kbhit():
                ch = msvcrt.getch()
                if ch == b'\xe0':
                    ch2 = msvcrt.getch()
                    if ch2 == b'H':       # ↑ 音量
                        vol = min(15, vol + 1); psg.set_vol(vol)
                    elif ch2 == b'P':     # ↓ 音量
                        vol = max(0, vol - 1); psg.set_vol(vol)
                    elif ch2 == b'M':     # → 升半音
                        note_idx = min(len(NOTE_LIST)-1, note_idx + 1); psg.set_period(cur_period())
                    elif ch2 == b'K':     # ← 降半音
                        note_idx = max(0, note_idx - 1); psg.set_period(cur_period())
                elif ch in (b'w', b'W'):
                    sel = (sel + 1) % 16; psg.set_sel(sel)
                elif ch in (b'e', b'E'):
                    sel = (sel - 1) % 16; psg.set_sel(sel)
                elif ch in (b'm', b'M'):
                    mode = 1 - mode; psg.set_mode(mode); psg.set_period(cur_period())
                    if mode:
                        psg.trigger()     # 切到采样模式自动触发一次
                elif ch in (b't', b'T'):
                    psg.trigger()
                elif ch == b' ':
                    vol = 0; psg.set_vol(vol)
                elif ch in (b'q', b'Q', b'\x1b'):
                    stop = True
                status(vol, note_idx, mode, sel)
            time.sleep(0.02)
    except KeyboardInterrupt:
        print("\nCtrl+C 退出")
    finally:
        # 无论 q/ESC 还是 Ctrl+C, 都先清音量频率再关设备
        psg.close()
        print("已静音 (vol=0, freq=最低), 设备关闭")


if __name__ == '__main__':
    main()
