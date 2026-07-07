#!/usr/bin/env python3
# psg_squaretest_v04.py — PSG3 v0.4 方波通道 (CH0) 手动测试
#
# 不跑 ADSR, 直接手动控制 reg0(period) + reg1(控制), 干净验证总线写入.
#   ↑/↓ = 音量 ±1 (0-15)
#   ←/→ = 频率 ±1 半音 (按当前占空比做八度补偿, 切占空比后音高不变)
#   D   = 占空比循环 (50%→25%→12.5%→25%@f4→50%)
#   W   = REF 切换 (bit7 toggle: 占空比变体↔Q0 调制)
#   S   = mode 切换 (bit6 toggle: 方波↔白噪)
#   0/空格 = 静音
#   q/ESC = 退出
#
# 寄存器 (独热码): reg0(0x01)=period, reg1(0x02)=控制(音量/占空比/mode/ref)
# FT232H: C0-C7=数据, D4=A0, D5=/WR, D6=/RST, D7=/CS

import ftd2xx
import time
import sys

try:
    import msvcrt
except ImportError:
    msvcrt = None

BIT_A0, BIT_WR, BIT_RST, BIT_CS = 4, 5, 6, 7
CLK_HZ = 64000

# 占空比挡 (bit4-5): (编码, 标签, 补偿八度数)
# 占空比变窄时频率同步降低 (每级÷2 降一个八度) — 硬件特性, 默认不补偿.
# ⚠️ 8-bit period 精度有限, 补偿引入额外量化误差, 默认全 0 (如实降八度).
# ⚠️ 编码据 PSG2 v0.3 硬件实测, 顺序为 50%→25%→12.5%→25%@f4 循环.
DUTY_LIST = [
    (0b11, '50%',     0),
    (0b01, '25%',     0),
    (0b00, '12.5%',   0),
    (0b10, '25%@f4',  0),
]

# C 大调音名 → 频率 (用于半音步进, ←/→ 一个半音)
NOTE_FREQS = {
    'C3':130.8,'C#3':138.6,'D3':146.8,'D#3':155.6,'E3':164.8,'F3':174.6,'F#3':185.0,
    'G3':196.0,'G#3':207.7,'A3':220.0,'A#3':233.1,'B3':246.9,
    'C4':261.6,'C#4':277.2,'D4':293.7,'D#4':311.1,'E4':329.6,'F4':349.2,'F#4':370.0,
    'G4':392.0,'G#4':415.3,'A4':440.0,'A#4':466.2,'B4':493.9,
    'C5':523.3,'C#5':554.4,'D5':587.3,'D#5':622.3,'E5':659.3,'F5':698.5,
    'G5':784.0,'A5':880.0,'B5':987.8,'C6':1046.5,
}
NOTE_NAMES = list(NOTE_FREQS.keys())   # 半音步进表


class Psg:
    """PSG3 v0.4 方波通道驱动 (YM2413 两拍写, 批量打包)."""
    def __init__(self):
        self.dev = ftd2xx.open(0)
        self.dev.resetDevice()
        self.dev.setBitMode(0x00, 0x02)
        M_A0, M_WR, M_RST, M_CS = 1<<BIT_A0, 1<<BIT_WR, 1<<BIT_RST, 1<<BIT_CS
        self._d = M_WR | M_RST | M_CS   # 空闲态: A0=0,WR=1,RST=1,CS=1
        self.dev.write(bytes([0x80, self._d, 0xFF]))   # D 口方向全输出
        self._c = 0
        time.sleep(0.05)
        # 音色状态
        self.duty = 0b11   # 50%
        self.mode = 0      # 方波
        self.ref  = 0      # 占空比变体
        self.reset()

    @staticmethod
    def _cmd_d(d_val):
        return bytes([0x80, d_val & 0xFF, 0xFF])

    @staticmethod
    def _cmd_c(c_val):
        return bytes([0x82, c_val & 0xFF, 0xFF])

    def _sd(self, bit, v):
        """D 口位操作 (零星用: reset/close)."""
        if v: self._d |= (1 << bit)
        else: self._d &= ~(1 << bit)
        self.dev.write(bytes([0x80, self._d & 0xFF, 0xFF]))
        time.sleep(2e-3)

    def _bus_write(self, addr, data):
        """YM2413 两拍写, MPSSE 批量打包.
        ⚠️ A0/CS 跳变必须在 WR=0 期间 (避免 strobe 误上升沿).
        addr_cp=cs&a0_n&wr, data_strobe=cs&A0&wr."""
        M_A0, M_WR, M_RST, M_CS = 1<<BIT_A0, 1<<BIT_WR, 1<<BIT_RST, 1<<BIT_CS
        RST = M_RST
        buf = bytearray()
        # 事务开始: WR=0 → CS=0
        buf += self._cmd_d(RST)
        buf += self._cmd_d(RST)
        # 第 1 拍写地址
        buf += self._cmd_c(addr)
        buf += self._cmd_d(RST)
        buf += self._cmd_d(RST | M_WR)                          # WR↑ 锁地址
        # 第 2 拍写数据: WR=0 → C口=数据 → A0=1 → WR↑
        buf += self._cmd_d(RST)
        buf += self._cmd_c(data)
        buf += self._cmd_d(RST | M_A0)
        buf += self._cmd_d(RST | M_A0 | M_WR)                  # WR↑ 锁数据
        # 事务结束: WR=0 → CS=1 → A0=0,WR=1
        buf += self._cmd_d(RST | M_A0)
        buf += self._cmd_d(RST | M_CS | M_A0)
        buf += self._cmd_d(RST | M_CS | M_WR)
        self.dev.write(bytes(buf))
        self._d = RST | M_CS | M_WR

    def reset(self):
        self._sd(BIT_RST, 0); time.sleep(2e-3)
        self._sd(BIT_RST, 1); time.sleep(2e-3)

    def set_period(self, p):
        """写 period 到 reg0 (独热码 0x01)."""
        p = max(0, min(255, int(p)))
        self._bus_write(0x01, p)

    def write_ctrl(self, vol):
        """写控制字到 reg1 (独热码 0x02):
           音量(bit0-3) | 占空比(bit4-5) | ref(bit6) | mode(bit7)."""
        vol = max(0, min(15, vol))
        ctrl = ((vol & 0x0F)
                | ((self.duty & 0x03) << 4)
                | ((self.ref & 1) << 6)
                | ((self.mode & 1) << 7))
        self._bus_write(0x02, ctrl)

    def close(self):
        try:
            self.write_ctrl(0)   # 音量归零
            self._d = (1 << BIT_CS)   # CS=1 (禁止锁存), RST=0 (按住计数器)
            self._c = 0
            self.dev.write(bytes([0x80, self._d, 0xFF]))
            time.sleep(0.02)
        except: pass
        self.dev.close()


def freq_to_period(freq, duty_oct):
    """按占空比补偿算 period. freq×2^N 升 N 八度, 再走 freq→period."""
    freq_comp = freq * (2 ** duty_oct)
    return max(1, min(255, round(256 - CLK_HZ / (2 * freq_comp))))


def status(vol, note_idx, duty_idx, mode, ref):
    note = NOTE_NAMES[note_idx]
    freq = NOTE_FREQS[note]
    duty_label = DUTY_LIST[duty_idx][1]
    mode_name = '白噪' if mode else '方波'
    ref_name = 'Q0调制' if ref else '占空比变体'
    print(f"\r  音={note}({freq:.1f}Hz)  vol={vol:2d}/15  占空比={duty_label:8s}  "
          f"mode={mode_name}  ref={ref_name}            ", end='', flush=True)


def main():
    psg = Psg()
    vol = 10
    note_idx = NOTE_NAMES.index('A4')   # 默认 A4
    duty_idx = 0                         # DUTY_LIST 索引, 默认 50%
    mode = 0
    ref = 0

    psg.duty = DUTY_LIST[duty_idx][0]
    psg.mode = mode
    psg.ref  = ref
    # 初始化: 写 period + 控制字
    psg.set_period(freq_to_period(NOTE_FREQS[NOTE_NAMES[note_idx]], DUTY_LIST[duty_idx][2]))
    psg.write_ctrl(vol)

    print("=== PSG3 v0.4 方波单独测试 ===")
    print("  ↑/↓ 音量 ±1")
    print("  ←/→ 频率 ±1 半音 (按占空比补偿, 音高不变)")
    print("  D 占空比循环 (50%→25%→12.5%→25%@f4)")
    print("  W REF 切换 (占空比变体↔Q0调制)")
    print("  S 方波/白噪切换")
    print("  0/空格 静音 | q/ESC 退出")
    print()
    status(vol, note_idx, duty_idx, mode, ref)
    print()

    stop = False
    while not stop:
        if msvcrt and msvcrt.kbhit():
            ch = msvcrt.getch()
            if ch == b'\xe0':
                ch2 = msvcrt.getch()
                if ch2 == b'H':     # ↑ 音量+
                    vol = min(15, vol + 1)
                    psg.write_ctrl(vol)
                elif ch2 == b'P':   # ↓ 音量-
                    vol = max(0, vol - 1)
                    psg.write_ctrl(vol)
                elif ch2 == b'M':   # → 频率+ (升半音)
                    note_idx = min(len(NOTE_NAMES)-1, note_idx + 1)
                    psg.set_period(freq_to_period(NOTE_FREQS[NOTE_NAMES[note_idx]], DUTY_LIST[duty_idx][2]))
                elif ch2 == b'K':   # ← 频率- (降半音)
                    note_idx = max(0, note_idx - 1)
                    psg.set_period(freq_to_period(NOTE_FREQS[NOTE_NAMES[note_idx]], DUTY_LIST[duty_idx][2]))
            elif ch in (b'd', b'D'):
                duty_idx = (duty_idx + 1) % len(DUTY_LIST)
                psg.duty = DUTY_LIST[duty_idx][0]
                # 切占空比后重算 period (按新补偿八度), 音高保持
                psg.set_period(freq_to_period(NOTE_FREQS[NOTE_NAMES[note_idx]], DUTY_LIST[duty_idx][2]))
                psg.write_ctrl(vol)
            elif ch in (b'w', b'W'):
                ref ^= 1
                psg.ref = ref
                psg.write_ctrl(vol)
            elif ch in (b's', b'S'):
                mode ^= 1
                psg.mode = mode
                psg.write_ctrl(vol)
            elif ch in (b'0', b' '):
                vol = 0
                psg.write_ctrl(0)
            elif ch in (b'q', b'Q', b'\x1b'):
                stop = True
            status(vol, note_idx, duty_idx, mode, ref)
        time.sleep(0.02)

    print("\n退出")
    psg.close()
    print("已静音, 设备关闭")


if __name__ == '__main__':
    main()
