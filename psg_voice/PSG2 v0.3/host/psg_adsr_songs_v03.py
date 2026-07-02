#!/usr/bin/env python3
# psg_adsr_songs_v03.py — PSG2 v0.3 ADSR 合成器 + 方波音色切换 (CH0)
#
# 在 v0.2 (ADSR+颤音+曲目库) 基础上, 启用 v0.3 方波通道新增控制位:
#   控制字 (HC374, A0=D5 选通):
#     bit0-3: 音量     (4 bit, 16 级, 与 v0.2 一致)
#     bit4-5: 占空比挡 (00=50% / 01=25% / 10=12.5% / 11=25%@f/4)
#     bit6:   mode     (0=方波, 1=白噪)        ← HC4053 开关 X
#     bit7:   REF      (0=占空比变体, 1=Q0调制) ← HC4053 开关 Z
#
# 键盘 (中断式响应, 与切歌逻辑相同):
#   n/b    = 下一首/上一首
#   ./,    = 加速/减速 (持久化到 ini)
#   v      = 颤音开关  ;/'  颤音频率+/-  [/]  颤音幅度+/-  -/=  颤音延迟+/-
#   D      = 占空比循环切换 (50%→25%→12.5%→25%@f4→50%)
#   W      = 波形/REF 切换 (bit7 toggle: 占空比变体↔Q0调制)
#   S      = 方波/白噪切换 (bit6 toggle)
#   q/ESC  = 退出
#
# 时钟: 64 kHz
# 引脚: C0-C7 数据, D4/D5/D6/D7 = LE/A0/RST/(A1 噪音, 本版不用)

import ftd2xx
import time
import threading
import sys
import math
import os
import configparser

try:
    import msvcrt   # Windows 键盘
except ImportError:
    msvcrt = None

# ============== PSG 硬件控制 ==============
BIT_LE, BIT_A0, BIT_RST = 4, 5, 6
CLK_HZ = 64000

# ============== 方波音色状态 (bit4-7) ==============
# 占空比挡 (bit4-5): 顺序循环
# ⚠️ 标签据硬件实测 (2026-07-03), 硬件实测为准:
#    00 实测 12.5% / 10 实测 6.25% / 11 实测 50%
# 元组: (bit4-5 编码, 标签, 默认补偿八度数)
#   补偿八度: 占空比变窄时频率同步降低 (每级÷2 降一个八度),
#   软件把 period 右移 N 位 (= ÷2^N) 升回原音高. 50% 不补偿 (N=0).
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
        # setBitMode 切换瞬间 D 口引脚状态不定, A0/LE 毛刺会触发 HC374/HC373 锁存随机数据.
        # 立即把 D 口全拉低 (A0=LE=RST=0), RST=0 期间计数器/触发器被按住, 避免毛刺噪音.
        # ⚠️ HC374 无 MR 脚不吃 RST, 但 A0=0 期间它不会锁存 (CP 无上升沿).
        self._d = 0xFF   # 先设全 1 (RST 高 = 不复位期), 方向已确定
        self.dev.write(bytes([0x80, self._d, 0xFF]))   # D 口方向全输出
        # 立刻拉低 A0/LE/RST, 杜绝毛刺上升沿
        self._d = 0; self._c = 0
        self.dev.write(bytes([0x80, self._d, 0xFF]))   # D 口全 0 (A0=LE=RST=0)
        time.sleep(0.05)
        self._vol = 0
        # v0.3 方波音色状态 (会被 ToneControl 实时改)
        # ⚠️ bit 位据硬件实测 (2026-07-03): bit6=REF, bit7=mode (与接线表文档相反, 以硬件为准)
        self.duty = 0b11   # 默认 50% (无补偿, 最干净音色)
        self.mode = 0      # bit7 mode (0=方波, 1=白噪)
        self.ref  = 0      # bit6 REF  (0=占空比变体, 1=Q0)
        self.reset()       # RST 脉冲 (复位 HC161, 此时 A0/LE=0 不会误锁存)
        self.init_audio()  # 启动: 置干净状态 (50%方波 + 频率最高听不见)

    def init_audio(self):
        """启动初始化: duty=50% / 方波模式 / ref=占空比变体 / 频率最高 (听不见).
        防止上电瞬间残留噪音. period=1 → freq=32kHz 超出可听范围."""
        self.duty = 0b11; self.mode = 0; self.ref = 0
        self.set_period(1)          # period=1 → 频率最高 (32kHz, 听不见)
        self.write_ctrl(0)          # 音量归零

    def shutdown(self):
        """退出清理: duty=50% / 方波模式 / 音量归零 / 频率最高 (听不见).
        防止退出后残留噪音 (尤其白噪模式)."""
        self.duty = 0b11; self.mode = 0; self.ref = 0
        self.set_period(1)
        self.write_ctrl(0)

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
        """写方波控制字: 音量(bit0-3) | 占空比(bit4-5) | REF(bit6) | mode(bit7).
        ⚠️ bit6/bit7 据硬件实测对调 (2026-07-03), 与接线表文档相反, 以硬件为准.
        ADSR 每次 tick 都调此方法, 保证音色位始终随音量一起写入."""
        vol = max(0, min(15, vol))
        self._vol = vol
        self._sd(BIT_LE, 0)
        self._c = ((vol & 0x0F)
                   | ((self.duty & 0x03) << 4)
                   | ((self.ref & 1) << 6)
                   | ((self.mode & 1) << 7))
        self.dev.write(bytes([0x82, self._c, 0xFF]))
        self._sd(BIT_A0, 1); self._sd(BIT_A0, 0)

    # v0.2 兼容别名 (Voice.tick 调用 volume, 这里转发到 write_ctrl)
    def volume(self, vol):
        self.write_ctrl(vol)

    def freq(self, f):
        if f <= 0:
            return 0.0
        p = max(1, min(255, round(256 - CLK_HZ / (2 * f))))
        self.set_period(p)
        return CLK_HZ / (2 * (256 - p))

    def set_period(self, p):
        """直接写 period 寄存器值 (1-255), 颤音微调用, 绕过 freq→p 换算."""
        p = max(0, min(255, int(p)))
        self._sd(BIT_A0, 0)
        self._c = p & 0xFF
        self.dev.write(bytes([0x82, self._c, 0xFF]))
        self._sd(BIT_LE, 1); self._sd(BIT_LE, 0)

    def close(self):
        try:
            self.shutdown()         # 退出: 干净状态 (50%方波/音量0/频率最高)
            # RST 持续拉低 (D口只清 A0/LE, 保留 RST=0 按住计数器),
            # 这样 dev.close() 引脚跳变时 HC161 被复位, 不会冒音.
            self._d = 0   # A0=LE=RST=0 全低
            self._c = 0
            self._wb()
            time.sleep(0.02)   # 等 RST 生效稳定
        except: pass
        self.dev.close()


# ============== ADSR 包络状态机 ==============
TICK = 0.005
S_LEVEL = 4     # 低延音 (突出衰减落差)
A_MS = 10       # Attack 固定 10ms (起音不随速度变)
D_MS = 300      # Decay 基准 300ms (会随 tempo 缩放)
R_MS = 30       # Release 基准 30ms (会随 tempo 缩放)

VIB_DELAY = 0.1
VIB_RATE  = 6.0
VIB_PERIOD_FRAC = 0.014
VIB_EVERY = 2

ENV_IDLE, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE = 0,1,2,3,4


class Voice:
    def __init__(self, psg):
        self.psg = psg
        self.state = ENV_IDLE
        self.vol = 0
        self.tick_cnt = 0
        self.rel_start = 0
        self.a_ticks = 2
        self.d_ticks = 60
        self.r_ticks = 6
        self.vib_enabled = False
        self.vib_rate = VIB_RATE
        self.vib_amp_frac = VIB_PERIOD_FRAC
        self.vib_delay = VIB_DELAY
        self.base_period = 0
        self.cur_freq = 0      # 当前音原始 freq (供 reapply_period 重算)
        self.total_ticks = 0
        self.vib_delay_ticks = 0
        self.vib_amp = 1.0
        self.duty_oct = None   # DutyOctave 引用, 由 main 注入; None 时不补偿
        self.set_tempo(0.22)

    def set_vibrato(self, enabled, rate=None, amp_frac=None, delay=None):
        self.vib_enabled = enabled
        if rate is not None:
            self.vib_rate = rate
        if amp_frac is not None:
            self.vib_amp_frac = amp_frac
            if self.base_period > 0:
                self.vib_amp = max(0.0, self.base_period * self.vib_amp_frac)
        if delay is not None:
            self.vib_delay = delay

    def set_tempo(self, beat_t):
        scale = beat_t / 0.22
        self.a_ticks = max(1, round((A_MS/1000) / TICK))
        self.d_ticks = max(8, round((D_MS/1000) / TICK * scale))
        self.r_ticks = max(2, round((R_MS/1000) / TICK * scale))

    def _compensated_period(self, freq):
        """按当前占空比补偿, 算补偿后 period.
        补偿 = 频率升 N 个八度 (freq × 2^N), 与移调同源 (非 period 右移).
        freq×2^N 再走 freq→period 正向换算, 保证音高精确."""
        if self.duty_oct is not None:
            oct = self.duty_oct.oct_for(self.psg.duty)
            freq = freq * (2 ** oct)   # 频率升 N 八度 (移调同款精确换算)
        return max(1, min(255, round(256 - CLK_HZ / (2 * freq))))

    def key_on(self, freq):
        if freq > 0:
            self.cur_freq = freq   # 记原始 freq, 供 reapply_period 重算
            self.base_period = self._compensated_period(freq)
            self.psg.set_period(self.base_period)   # 直接写补偿后 period (不走 Psg.freq)
            self.vib_amp = max(0.0, self.base_period * self.vib_amp_frac)
        else:
            self.base_period = 0
            self.cur_freq = 0
        self.state = ENV_ATTACK
        self.tick_cnt = 0
        self.total_ticks = 0
        self.vib_delay_ticks = self.a_ticks + round(self.vib_delay / TICK)

    def reapply_period(self):
        """切占空比后实时重算当前音的 period (不打断 ADSR).
        用记录的原始 freq + 新占空比补偿重新算 period."""
        if self.cur_freq > 0 and self.duty_oct is not None:
            new_period = self._compensated_period(self.cur_freq)
            self.base_period = new_period
            self.vib_amp = max(0.0, self.base_period * self.vib_amp_frac)
            # 非颤音段直接写; 颤音段下次 tick 会用新 base_period 覆盖
            if not (self.vib_enabled and self.state in (ENV_DECAY, ENV_SUSTAIN)
                    and self.total_ticks > self.vib_delay_ticks):
                self.psg.set_period(new_period)

    def key_off(self):
        if self.state != ENV_IDLE:
            self.state = ENV_RELEASE
            self.tick_cnt = 0
            self.rel_start = self.vol
            if self.vib_enabled and self.base_period > 0:
                self.psg.set_period(self.base_period)

    def silence(self):
        self.state = ENV_IDLE
        self.vol = 0
        self.psg.volume(0)

    def tick(self):
        self.total_ticks += 1
        if self.state == ENV_ATTACK:
            self.tick_cnt += 1
            self.vol = min(15, round(15 * self.tick_cnt / self.a_ticks))
            if self.tick_cnt >= self.a_ticks:
                self.vol = 15; self.state = ENV_DECAY; self.tick_cnt = 0
        elif self.state == ENV_DECAY:
            self.tick_cnt += 1
            self.vol = max(S_LEVEL, round(15 - (15 - S_LEVEL) * self.tick_cnt / self.d_ticks))
            if self.tick_cnt >= self.d_ticks:
                self.vol = S_LEVEL; self.state = ENV_SUSTAIN
        elif self.state == ENV_SUSTAIN:
            self.vol = S_LEVEL
        elif self.state == ENV_RELEASE:
            self.tick_cnt += 1
            self.vol = max(0, round(self.rel_start * (1 - self.tick_cnt / self.r_ticks)))
            if self.tick_cnt >= self.r_ticks:
                self.vol = 0; self.state = ENV_IDLE
        # 写音量 (经 write_ctrl 自动带上当前音色位)
        if self.state != ENV_IDLE or self.vol != 0:
            self.psg.volume(self.vol)
        if (self.vib_enabled and self.base_period > 0
                and self.state in (ENV_DECAY, ENV_SUSTAIN)
                and self.total_ticks > self.vib_delay_ticks
                and self.total_ticks % VIB_EVERY == 0):
            t = self.total_ticks * TICK
            phase = (t * self.vib_rate) % 1.0
            if phase < 0.25:
                tri = phase * 4
            elif phase < 0.75:
                tri = 2.0 - phase * 4
            else:
                tri = phase * 4 - 4.0
            p_mod = round(self.base_period + self.vib_amp * tri)
            self.psg.set_period(p_mod)


# ============== 简谱 -> 频率 ==============
NOTE_SEMITONE = {1:0, 2:2, 3:4, 4:5, 5:7, 6:9, 7:11}

KEY_SEMITONE = {
    'C': 0, 'C#': 1, 'Db': 1, 'D': 2, 'D#': 3, 'Eb': 3,
    'E': 4, 'Fb': 4, 'E#': 5, 'F': 5, 'F#': 6, 'Gb': 6,
    'G': 7, 'G#': 8, 'Ab': 8, 'A': 9, 'A#': 10, 'Bb': 10,
    'B': 11, 'Cb': 11, 'B#': 0,
}

def _key_semi_to_name(semi):
    names = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B']
    return names[semi % 12]

def jianpu_freq(degree, octave, key_semi=0, accidental=0):
    midi = 12 * (octave + 1) + NOTE_SEMITONE[degree] + key_semi + accidental
    return 440.0 * (2 ** ((midi - 69) / 12.0))


# ============== 曲目库 (从 ini 加载) ==============
INI_SONGS = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'psg_songs.ini')


def parse_notes(text):
    notes = []
    for tok in text.replace('|', ' ').split():
        oct_ov = None
        degree_str = tok
        if tok[0] == '^':
            oct_ov = (5,); degree_str = tok[1:]
        elif tok[0] == ',':
            oct_ov = (3,); degree_str = tok[1:]
        if ':' not in degree_str:
            print(f"  (警告: 无法解析音符 '{tok}', 跳过)", flush=True)
            continue
        d_str, b_str = degree_str.split(':', 1)
        accidental = 0
        if d_str and d_str[-1] == '+':
            accidental = 1; d_str = d_str[:-1]
        elif d_str and d_str[-1] == '-':
            accidental = -1; d_str = d_str[:-1]
        try:
            d = int(d_str); b = float(b_str)
        except ValueError:
            print(f"  (警告: 音符格式错 '{tok}', 跳过)", flush=True)
            continue
        if not (0 <= d <= 7):
            print(f"  (警告: 音级超范围 '{tok}', 跳过)", flush=True)
            continue
        notes.append((d, b, oct_ov, accidental, tok))
    return notes


def split_notes_lines(notes_text, notes):
    lines = [ln for ln in notes_text.split('\n') if ln.strip()]
    result = []
    idx = 0
    for ln in lines:
        cnt = len([t for t in ln.replace('|', ' ').split()])
        result.append(notes[idx:idx+cnt])
        idx += cnt
    if idx < len(notes):
        if result:
            result[-1].extend(notes[idx:])
        else:
            result.append(notes[idx:])
    return result


def load_songs():
    cp = configparser.ConfigParser()
    if not cp.read(INI_SONGS, encoding='utf-8'):
        print(f"(错误: 找不到曲目库 {INI_SONGS})")
        return []
    songs = []
    items = []
    for sec in cp.sections():
        if sec.startswith('song_'):
            try:
                n = int(sec[5:])
            except ValueError:
                continue
            items.append((n, sec))
    items.sort()
    for n, sec in items:
        name = cp.get(sec, 'name', fallback=f'未命名{n}')
        octave = cp.getint(sec, 'octave', fallback=4)
        key_str = cp.get(sec, 'key', fallback='C').strip()
        key_octave_shift = 0
        key_name = key_str
        if key_str.startswith('^'):
            key_octave_shift = 1; key_name = key_str[1:]
        elif key_str.startswith(','):
            key_octave_shift = -1; key_name = key_str[1:]
        key_semi = KEY_SEMITONE.get(key_name, 0)
        if key_name.upper() not in KEY_SEMITONE and key_name not in KEY_SEMITONE:
            print(f"  (警告: 曲目 {name} 的 key='{key_str}' 无法识别, 按 C 处理)", flush=True)
        notes_text = cp.get(sec, 'notes', fallback='')
        notes = parse_notes(notes_text)
        if notes:
            notes_lines = split_notes_lines(notes_text, notes)
            songs.append((name, octave, key_semi, key_octave_shift, notes, notes_lines))
    return songs



# ============== 键盘控制 (独立线程, 中断式) ==============
class SongSelector:
    def __init__(self, n_songs):
        self.n_songs = n_songs
        self.idx = 0
        self.changed = threading.Event()
        self.lock = threading.Lock()
        self._stop = False

    def next(self):
        with self.lock:
            self.idx = (self.idx + 1) % self.n_songs
            self.changed.set()

    def prev(self):
        with self.lock:
            self.idx = (self.idx - 1) % self.n_songs
            self.changed.set()

    def get(self):
        with self.lock:
            return self.idx

    def consume_change(self):
        return self.changed.is_set()

    def clear_change(self):
        self.changed.clear()

    def stop(self):
        self._stop = True


# ============== 速度控制 (持久化到 ini) ==============
INI_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'psg_config.ini')

class TempoControl:
    def __init__(self, default=0.22):
        self.beat_t = default
        self.step = 0.02
        self.lo, self.hi = 0.10, 0.50
        self.vib_enabled = True
        self.vib_rate = VIB_RATE
        self.vib_step = 0.5
        self.vib_lo, self.vib_hi = 2.0, 12.0
        self.vib_amp_frac = VIB_PERIOD_FRAC
        self.vib_amp_step = 0.003
        self.vib_amp_lo, self.vib_amp_hi = 0.0, 0.0285
        self.vib_delay = VIB_DELAY
        self.vib_delay_step = 0.02
        self.vib_delay_lo, self.vib_delay_hi = 0.0, 1.0
        self.lock = threading.Lock()
        self.changed = threading.Event()
        self.vib_changed = threading.Event()
        self.load()

    def load(self):
        try:
            cp = configparser.ConfigParser()
            if os.path.exists(INI_PATH):
                cp.read(INI_PATH, encoding='utf-8')
                if cp.has_option('tempo', 'beat_t'):
                    self.beat_t = max(self.lo, min(self.hi, cp.getfloat('tempo', 'beat_t')))
                if cp.has_option('vibrato', 'enabled'):
                    self.vib_enabled = cp.getboolean('vibrato', 'enabled')
                if cp.has_option('vibrato', 'rate'):
                    self.vib_rate = max(self.vib_lo, min(self.vib_hi, cp.getfloat('vibrato', 'rate')))
                if cp.has_option('vibrato', 'amp_frac'):
                    self.vib_amp_frac = max(self.vib_amp_lo, min(self.vib_amp_hi, cp.getfloat('vibrato', 'amp_frac')))
                if cp.has_option('vibrato', 'delay'):
                    self.vib_delay = max(self.vib_delay_lo, min(self.vib_delay_hi, cp.getfloat('vibrato', 'delay')))
        except Exception as e:
            print(f"(ini 读取失败, 用默认: {e})")

    def save(self):
        try:
            cp = configparser.ConfigParser()
            cp['tempo'] = {'beat_t': f'{self.beat_t:.3f}'}
            cp['vibrato'] = {'enabled': '1' if self.vib_enabled else '0',
                             'rate': f'{self.vib_rate:.2f}',
                             'amp_frac': f'{self.vib_amp_frac:.4f}',
                             'delay': f'{self.vib_delay:.3f}'}
            with open(INI_PATH, 'w', encoding='utf-8') as f:
                cp.write(f)
        except Exception as e:
            print(f"(ini 写入失败: {e})")

    def toggle_vibrato(self):
        with self.lock:
            self.vib_enabled = not self.vib_enabled
            self.vib_changed.set()
            self.save()

    def vib_rate_up(self):
        with self.lock:
            self.vib_rate = min(self.vib_hi, round(self.vib_rate + self.vib_step, 2))
            self.vib_changed.set(); self.save()

    def vib_rate_down(self):
        with self.lock:
            self.vib_rate = max(self.vib_lo, round(self.vib_rate - self.vib_step, 2))
            self.vib_changed.set(); self.save()

    def vib_amp_up(self):
        with self.lock:
            self.vib_amp_frac = min(self.vib_amp_hi, round(self.vib_amp_frac + self.vib_amp_step, 4))
            self.vib_changed.set(); self.save()

    def vib_amp_down(self):
        with self.lock:
            self.vib_amp_frac = max(self.vib_amp_lo, round(self.vib_amp_frac - self.vib_amp_step, 4))
            self.vib_changed.set(); self.save()

    def vib_delay_up(self):
        with self.lock:
            self.vib_delay = min(self.vib_delay_hi, round(self.vib_delay + self.vib_delay_step, 3))
            self.vib_changed.set(); self.save()

    def vib_delay_down(self):
        with self.lock:
            self.vib_delay = max(self.vib_delay_lo, round(self.vib_delay - self.vib_delay_step, 3))
            self.vib_changed.set(); self.save()

    def faster(self):
        with self.lock:
            self.beat_t = max(self.lo, round(self.beat_t - self.step, 3))
            self.changed.set(); self.save()

    def slower(self):
        with self.lock:
            self.beat_t = min(self.hi, round(self.beat_t + self.step, 3))
            self.changed.set(); self.save()

    def get(self):
        with self.lock:
            return self.beat_t

    def consume_change(self):
        return self.changed.is_set()

    def clear_change(self):
        self.changed.clear()


# ============== 方波音色控制 (v0.3 新增) ==============
class ToneControl:
    """管理方波通道的音色状态 (占空比/mode/REF). 线程安全, 中断式响应键盘.
    状态直接写入 Psg 实例的 duty/mode/ref 字段, 由下一次 write_ctrl 带到硬件."""
    def __init__(self, psg):
        self.psg = psg
        self.duty_idx = 3   # DUTY_LIST 索引, 默认 50% (与 Psg.init_audio 一致)
        self.lock = threading.Lock()
        self.changed = threading.Event()
        self._apply()       # 初始化硬件音色位

    def _apply(self):
        """把当前状态写进 Psg 的 duty/mode/ref 字段 (不触发硬件写, 等下一次 ADSR tick)."""
        with self.lock:
            self.psg.duty = DUTY_LIST[self.duty_idx][0]
            # mode/ref 直接用 psg 字段 (toggle_tone 改)

    def cycle_duty(self):
        """D 键: 占空比循环 50%→25%→12.5%→25%@f4→50%"""
        with self.lock:
            self.duty_idx = (self.duty_idx + 1) % len(DUTY_LIST)
            self.psg.duty = DUTY_LIST[self.duty_idx][0]
            self.changed.set()

    def toggle_mode(self):
        """S 键: 方波/白噪切换 (bit6)"""
        with self.lock:
            self.psg.mode ^= 1
            self.changed.set()

    def toggle_ref(self):
        """W 键: REF 切换 占空比变体↔Q0调制 (bit7)"""
        with self.lock:
            self.psg.ref ^= 1
            self.changed.set()

    def status_str(self):
        with self.lock:
            duty_name = DUTY_LIST[self.duty_idx][1]
            mode_name = '白噪' if self.psg.mode else '方波'
            ref_name  = 'Q0调制' if self.psg.ref else '占空比变体'
            return f"占空比={duty_name} mode={mode_name} REF={ref_name}"

    def consume_change(self):
        return self.changed.is_set()

    def clear_change(self):
        self.changed.clear()


# ============== 占空比八度补偿 (v0.3 新增) ==============
class DutyOctave:
    """占空比变窄时频率同步降低 (每级÷2 降一个八度), 软件补偿把 period 右移 N 位升回原音高.
    补偿值从 psg_config.ini [Duty] 块读, 键名 duty_<bit4-5编码> (duty_0..duty_3),
    值 = 升高几个八度 (0=不补偿). 缺省用 DUTY_LIST 第三字段的默认值."""
    def __init__(self):
        # 默认补偿表: {duty编码: 八度数}, 据硬件实测频率关系
        self.oct = {code: default_oct for (code, _name, default_oct) in DUTY_LIST}
        self.lock = threading.Lock()
        self.load()

    def load(self):
        """从 ini [Duty] 块加载补偿值 (覆盖默认)."""
        try:
            cp = configparser.ConfigParser()
            if os.path.exists(INI_PATH):
                cp.read(INI_PATH, encoding='utf-8')
                if cp.has_section('Duty'):
                    for code in range(4):
                        key = f'duty_{code}'
                        if cp.has_option('Duty', key):
                            v = cp.getint('Duty', key)
                            if v < 0:
                                print(f"  (警告: {key}={v} 不能为负, 用默认)", flush=True)
                                continue
                            self.oct[code] = v
        except Exception as e:
            print(f"([Duty] 读取失败, 用默认: {e})")

    def oct_for(self, duty_code):
        """返回指定 duty 编码 (0-3) 的补偿八度数."""
        with self.lock:
            return self.oct.get(duty_code, 0)

    def status_str(self):
        with self.lock:
            parts = []
            for code in range(4):
                name = next(n for (c, n, _o) in DUTY_LIST if c == code)
                parts.append(f"{name}→+{self.oct[code]}oct")
            return '  '.join(parts)


def keyboard_thread(selector, tempo, tone):
    """独立线程监听键盘. n/b 切歌, ./, 调速, v/;/'/[/]/-/= 颤音, D/W/S 音色, q 退出."""
    while not selector._stop:
        if msvcrt and msvcrt.kbhit():
            ch = msvcrt.getch()
            if ch in (b'n', b'N'):
                selector.next()
                print("\n>>> [下一首]", flush=True)
            elif ch in (b'b', b'B'):
                selector.prev()
                print("\n>>> [上一首]", flush=True)
            elif ch == b'.':
                tempo.faster()
                print(f"\n>>> [加速] beat_t={tempo.get():.3f}s", flush=True)
            elif ch == b',':
                tempo.slower()
                print(f"\n>>> [减速] beat_t={tempo.get():.3f}s", flush=True)
            elif ch in (b'v', b'V'):
                tempo.toggle_vibrato()
                print(f"\n>>> [颤音] {'开' if tempo.vib_enabled else '关'}", flush=True)
            elif ch == b';':
                tempo.vib_rate_up()
                print(f"\n>>> [颤音频率] {tempo.vib_rate:.1f}Hz", flush=True)
            elif ch == b"'":
                tempo.vib_rate_down()
                print(f"\n>>> [颤音频率] {tempo.vib_rate:.1f}Hz", flush=True)
            elif ch == b']':
                tempo.vib_amp_up()
                print(f"\n>>> [颤音幅度] period×{tempo.vib_amp_frac:.4f}", flush=True)
            elif ch == b'[':
                tempo.vib_amp_down()
                print(f"\n>>> [颤音幅度] period×{tempo.vib_amp_frac:.4f}", flush=True)
            elif ch == b'-':
                tempo.vib_delay_down()
                print(f"\n>>> [颤音延迟] {tempo.vib_delay:.3f}s", flush=True)
            elif ch == b'=':
                tempo.vib_delay_up()
                print(f"\n>>> [颤音延迟] {tempo.vib_delay:.3f}s", flush=True)
            elif ch in (b'd', b'D'):       # v0.3: 占空比循环
                tone.cycle_duty()
                print(f"\n>>> [占空比] {tone.status_str()}", flush=True)
            elif ch in (b's', b'S'):       # v0.3: 方波/白噪
                tone.toggle_mode()
                print(f"\n>>> [mode] {tone.status_str()}", flush=True)
            elif ch in (b'w', b'W'):       # v0.3: REF 切换
                tone.toggle_ref()
                print(f"\n>>> [REF] {tone.status_str()}", flush=True)
            elif ch in (b'q', b'Q', b'\x1b'):
                selector.stop()
                print("\n>>> [退出]", flush=True)
                return
        time.sleep(0.02)


# ============== 播放 ==============
def play_note_env(voice, freq, dur):
    if freq <= 0:
        voice.silence()
        n = int(dur / TICK)
        for _ in range(n):
            time.sleep(TICK)
        return
    voice.key_on(freq)
    n = int(dur / TICK)
    for _ in range(n):
        voice.tick()
        time.sleep(TICK)
    voice.key_off()
    for _ in range(voice.r_ticks + 2):
        voice.tick()
        time.sleep(TICK)


def play_song(psg, voice, name, base_octave, key_semi, key_octave_shift, notes, notes_lines,
              selector, tempo, tone):
    """播放一首歌. 中途被切歌/调速/音色变化会即时响应.
    音色 (D/W/S) 不打断播放, 只在下一个 ADSR tick 经 write_ctrl 写入硬件."""
    beat_t = tempo.get()
    oct_marker = ('^' if key_octave_shift > 0 else ',' if key_octave_shift < 0 else '')
    print(f"\n♪ {name} ♪  (beat_t={beat_t:.3f}s, key={oct_marker}{_key_semi_to_name(key_semi)})", flush=True)

    def check_interrupt():
        """返回 True=被切歌打断. 音色变化不打断, 只消费标志."""
        if selector.consume_change():
            selector.clear_change()
            voice.silence()
            psg.volume(0); psg.reset()
            return True
        if tempo.consume_change():
            tempo.clear_change()
            beat_t = tempo.get()
            voice.set_tempo(beat_t)
            print(f"\n   [速度更新] beat_t={beat_t:.3f}s", flush=True)
        if tempo.vib_changed.is_set():
            tempo.vib_changed.clear()
            voice.set_vibrato(tempo.vib_enabled, tempo.vib_rate, tempo.vib_amp_frac, tempo.vib_delay)
        # 音色变化只消费标志, 实际硬件写在 Voice.tick → write_ctrl
        if tone.consume_change():
            tone.clear_change()
            print(f"\n   [音色更新] {tone.status_str()}", flush=True)
            # 静音状态立即刷新控制字 (否则音色位要等下一个音才生效)
            if voice.state == ENV_IDLE:
                psg.volume(0)
            # 占空比变了 → 实时重算当前音 period (补偿八度), 不打断 ADSR
            voice.reapply_period()
        return False

    for line in notes_lines:
        if check_interrupt(): return False
        print("  播放| ", end='', flush=True)
        for item in line:
            if check_interrupt(): return False
            degree, beats, oct_override, accidental, raw_tok = item
            oct_use = (oct_override[0] if oct_override is not None else base_octave) + key_octave_shift
            dur = beats * beat_t
            print(f"[{raw_tok}]", end=' ', flush=True)
            if degree == 0:
                voice.silence()
                for _ in range(int(dur / TICK)):
                    if check_interrupt(): return False
                    time.sleep(TICK)
            else:
                f = jianpu_freq(degree, oct_use, key_semi, accidental)
                play_note_env(voice, f, dur)
        print()
    time.sleep(0.3)
    return True


def main():
    import argparse
    parser = argparse.ArgumentParser(description='PSG2 v0.3 ADSR 合成器 (方波通道)')
    parser.add_argument('--song', type=int, default=None,
                        help='只播放指定曲目 (1-N) 无限循环, 不指定则循环全部')
    args = parser.parse_args()

    songs = load_songs()
    if not songs:
        print("无曲目, 请检查 psg_songs.ini")
        return
    print(f"(已加载 {len(songs)} 首曲目: {', '.join(s[0] for s in songs)})")

    single_song = None
    start_idx = 0
    if args.song is not None:
        if not (1 <= args.song <= len(songs)):
            print(f"错误: --song 范围 1-{len(songs)}, 你给的是 {args.song}")
            return
        single_song = args.song - 1
        start_idx = single_song
        print(f"(单曲循环模式: 只播 #{args.song} {songs[single_song][0]})")

    psg = Psg()
    voice = Voice(psg)
    selector = SongSelector(len(songs))
    selector.idx = start_idx
    tempo = TempoControl()
    tone = ToneControl(psg)   # v0.3 方波音色控制
    duty_oct = DutyOctave()   # v0.3 占空比八度补偿 (从 ini [Duty] 读)
    voice.duty_oct = duty_oct # 注入 Voice, key_on/reapply_period 时查补偿
    voice.set_tempo(tempo.get())
    voice.set_vibrato(tempo.vib_enabled, tempo.vib_rate, tempo.vib_amp_frac, tempo.vib_delay)
    kb = threading.Thread(target=keyboard_thread, args=(selector, tempo, tone), daemon=True)
    kb.start()

    print("=== PSG2 v0.3 ADSR 合成器 (方波通道 CH0) ===")
    print("    键盘: n/b 切歌  ./, 速度  v 颤音开关  ;/' 颤音频率  [/] 颤音幅度  -/= 颤音延迟")
    print("    音色: D=占空比循环  S=方波/白噪  W=REF切换(占空比变体/Q0调制)  q 退出")
    if single_song is not None:
        print(f"    单曲循环: #{args.song} (n/b 仍可切到其它曲, 但播完后回到 #{args.song})")
    else:
        print("    不操作则自动循环全部曲目")
    print(f"    初始 beat_t={tempo.get():.3f}s  颤音:{'开' if tempo.vib_enabled else '关'} {tempo.vib_rate:.1f}Hz 幅度×{tempo.vib_amp_frac:.4f} 延迟{tempo.vib_delay:.2f}s")
    print(f"    音色: {tone.status_str()}")
    print(f"    占空比补偿: {duty_oct.status_str()}")
    print(f"    ADSR: A{A_MS}ms D{D_MS}ms(随速度) S={S_LEVEL} R{R_MS}ms(随速度)\n")

    try:
        while not selector._stop:
            idx = selector.get()
            name, oct, key_semi, key_octave_shift, notes, notes_lines = songs[idx]
            psg.reset()
            voice.silence()
            psg.volume(0)
            print(f"\n########## 曲目 {idx+1}/{len(songs)} ##########", flush=True)
            selector.clear_change()
            tempo.clear_change()
            tone.clear_change()
            finished = play_song(psg, voice, name, oct, key_semi, key_octave_shift,
                                 notes, notes_lines, selector, tempo, tone)
            if not finished:
                continue
            if single_song is not None:
                with selector.lock:
                    selector.idx = single_song
            else:
                selector.next()
            selector.clear_change()
    except KeyboardInterrupt:
        print("\n停止")
    finally:
        selector.stop()         # 先停键盘线程 (避免和退出写入竞争)
        time.sleep(0.05)        # 等键盘线程退出
        psg.shutdown()          # 强制干净状态: 50%方波/mode=0/vol=0/最高频 (防残留白噪)
        psg._sd(BIT_RST, 0)     # RST 拉低 (持续复位=静音)
        psg.close()
        print("已静音, 设备关闭")

if __name__ == '__main__':
    main()
