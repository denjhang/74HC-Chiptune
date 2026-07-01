#!/usr/bin/env python3
# psg_adsr_songs_v02.py — PSG v0.2 ADSR 包络合成器 + 7 首中外曲目
#
# 功能:
#   - 钢琴风格 ADSR 包络 (A快/D明显/S低/R快), D/R 随速度缩放
#   - 7 首中外儿歌/民谣循环播放
#   - 键盘 n=下一首, b=上一首 (独立线程, 中断式响应)
#   - 键盘 .=加速 ,=减速 (速度持久化到 psg_config.ini, 包络同步缩放)
#   - 键盘 v=颤音开关  ;=颤音频率+  '=颤音频率- (持久化到 ini; 起音后0.1s开始, 到release结束)
#   - 切歌时 RST 复位 + 音量清零
#   - 不操作则自动循环全部曲目
#
# 时钟: 64 kHz
# 引脚: C0-C7 数据, D4/D5/D6 = LE/A0/RST

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
            self.volume(0)
            self._d = 0; self._c = 0; self._wb()
        except: pass
        self.dev.close()


# ============== ADSR 包络状态机 ==============
TICK = 0.005
S_LEVEL = 4     # 低延音 (突出衰减落差)
# A/D/R 的 ticks 随 tempo 缩放, 见 Voice.set_tempo()
A_MS = 10       # Attack 固定 10ms (起音不随速度变)
D_MS = 300      # Decay 基准 300ms (会随 tempo 缩放)
R_MS = 30       # Release 基准 30ms (会随 tempo 缩放)

# 颤音参数 (可通过 ini [vibrato] 开关)
# 颤音 = period 寄存器的三角波偏移, 幅度限制在半个半音之内.
# 半个半音对应 period 偏移 ≈ p × (1 - 1/2^(1/24)) ≈ p × 0.0285;
# 取其一半 (≈ p × 0.014) 保守留在半个半音以内.
VIB_DELAY = 0.1          # 起音结束后延迟多久开始颤音 (秒)
VIB_RATE  = 6.0          # 颤音频率 (Hz, 每秒振荡次数)
VIB_PERIOD_FRAC = 0.014  # period 偏移幅度 = base_period × 此值 (≤ 半个半音)
VIB_EVERY = 2            # 每隔几个 tick 更新一次 period (省通信开销)

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
        # 颤音
        self.vib_enabled = False
        self.vib_rate = VIB_RATE          # 颤音频率 (可由键盘调)
        self.vib_amp_frac = VIB_PERIOD_FRAC  # 颤音幅度比例 (可由键盘调)
        self.vib_delay = VIB_DELAY        # 颤音延迟 (起音后多少秒开始, 可调)
        self.base_period = 0      # 当前音基础 period (整数)
        self.total_ticks = 0      # key_on 起的总 tick (含 A 段)
        self.vib_delay_ticks = 0  # 颤音延迟 (A 结束后多少 tick 才开始)
        self.vib_amp = 1.0        # period 偏移幅度 (= base_period × vib_amp_frac)
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
        """速度变化时同步包络时长: A 固定, D/R 随 beat_t 缩放.
        beat_t 越小 (越快) → D/R 越短, 反之越长."""
        scale = beat_t / 0.22   # 以 0.22 为基准
        self.a_ticks = max(1, round((A_MS/1000) / TICK))                 # A 不缩放
        self.d_ticks = max(8, round((D_MS/1000) / TICK * scale))         # D 缩放
        self.r_ticks = max(2, round((R_MS/1000) / TICK * scale))         # R 缩放

    def key_on(self, freq):
        if freq > 0:
            actual = self.psg.freq(freq)
            # 算出当前 period (与 Psg.freq 同公式)
            self.base_period = max(1, min(255, round(256 - CLK_HZ / (2 * freq))))
            # 颤音幅度 = base_period × vib_amp_frac
            self.vib_amp = max(0.0, self.base_period * self.vib_amp_frac)
        else:
            self.base_period = 0
        self.state = ENV_ATTACK
        self.tick_cnt = 0
        self.total_ticks = 0
        self.vib_delay_ticks = self.a_ticks + round(self.vib_delay / TICK)

    def key_off(self):
        if self.state != ENV_IDLE:
            self.state = ENV_RELEASE
            self.tick_cnt = 0
            self.rel_start = self.vol
            # release 时恢复基础 period
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
        # 写音量
        if self.state != ENV_IDLE or self.vol != 0:
            self.psg.volume(self.vol)
        # 颤音: DECAY/SUSTAIN 段, 过了延迟且未到 RELEASE, 每 VIB_EVERY tick 用三角波偏移 period
        if (self.vib_enabled and self.base_period > 0
                and self.state in (ENV_DECAY, ENV_SUSTAIN)
                and self.total_ticks > self.vib_delay_ticks
                and self.total_ticks % VIB_EVERY == 0):
            # 三角波: phase 0→1→0→-1→0, 周期 = 1/vib_rate 秒
            t = self.total_ticks * TICK
            phase = (t * self.vib_rate) % 1.0      # 0~1 锯齿
            # 锯齿 → 三角: 0~0.25 升 0→1, 0.25~0.75 降 1→-1, 0.75~1 升 -1→0
            if phase < 0.25:
                tri = phase * 4                      # 0 → 1
            elif phase < 0.75:
                tri = 2.0 - phase * 4                # 1 → -1
            else:
                tri = phase * 4 - 4.0                # -1 → 0
            p_mod = round(self.base_period + self.vib_amp * tri)
            self.psg.set_period(p_mod)



# ============== 简谱 -> 频率 ==============
NOTE_SEMITONE = {1:0, 2:2, 3:4, 4:5, 5:7, 6:9, 7:11}
def jianpu_freq(degree, octave):
    midi = 12 * (octave + 1) + NOTE_SEMITONE[degree]
    return 440.0 * (2 ** ((midi - 69) / 12.0))


# ============== 曲目库 (从 ini 加载, 用户可在 psg_songs.ini 编辑) ==============
# ini 格式见 psg_songs.ini 开头注释.
# 音符文本格式: 音级:拍数 (^高八度  ,低八度  0休止)  分隔: 空格或 |
INI_SONGS = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'psg_songs.ini')


def parse_notes(text):
    """解析 ini 的 notes 文本 -> [(degree, beats, oct_override_or_None), ...]
    格式: '3:1 ^1:0.5 0:1 ,5:2'  (| 视为空格)"""
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
        try:
            d = int(d_str); b = float(b_str)
        except ValueError:
            print(f"  (警告: 音符格式错 '{tok}', 跳过)", flush=True)
            continue
        if not (0 <= d <= 7):
            print(f"  (警告: 音级超范围 '{tok}', 跳过)", flush=True)
            continue
        notes.append((d, b, oct_ov) if oct_ov else (d, b))
    return notes


def load_songs():
    """从 psg_songs.ini 加载曲目 -> [(name, base_octave, notes), ...] 按 song_N 排序."""
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
        notes_text = cp.get(sec, 'notes', fallback='')
        notes = parse_notes(notes_text)
        if notes:
            songs.append((name, octave, notes))
    return songs



# ============== 键盘控制 (独立线程, 中断式) ==============
class SongSelector:
    """线程安全的曲目选择器. n=下一首, b=上一首."""
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
        """消费'已切换'标志, 返回是否有切换."""
        return self.changed.is_set()

    def clear_change(self):
        self.changed.clear()

    def stop(self):
        self._stop = True


# ============== 速度控制 (持久化到 ini) ==============

INI_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'psg_config.ini')

class TempoControl:
    """管理播放速度 beat_t + 颤音 (开关/频率). 持久化到 ini."""
    def __init__(self, default=0.22):
        self.beat_t = default
        self.step = 0.02
        self.lo, self.hi = 0.10, 0.50
        self.vib_enabled = True   # 颤音默认开
        self.vib_rate = VIB_RATE  # 颤音频率 Hz (默认 6)
        self.vib_step = 0.5       # 颤音频率调节步进
        self.vib_lo, self.vib_hi = 2.0, 12.0
        self.vib_amp_frac = VIB_PERIOD_FRAC  # 颤音幅度 (period 偏移比例)
        self.vib_amp_step = 0.003            # 幅度调节步进
        self.vib_amp_lo, self.vib_amp_hi = 0.0, 0.0285  # 0 ~ 半个半音
        self.vib_delay = VIB_DELAY           # 颤音延迟 (起音后多少秒开始)
        self.vib_delay_step = 0.02           # 延迟调节步进
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
            self.vib_changed.set()
            self.save()

    def vib_rate_down(self):
        with self.lock:
            self.vib_rate = max(self.vib_lo, round(self.vib_rate - self.vib_step, 2))
            self.vib_changed.set()
            self.save()

    def vib_amp_up(self):
        with self.lock:
            self.vib_amp_frac = min(self.vib_amp_hi, round(self.vib_amp_frac + self.vib_amp_step, 4))
            self.vib_changed.set()
            self.save()

    def vib_amp_down(self):
        with self.lock:
            self.vib_amp_frac = max(self.vib_amp_lo, round(self.vib_amp_frac - self.vib_amp_step, 4))
            self.vib_changed.set()
            self.save()

    def vib_delay_up(self):
        with self.lock:
            self.vib_delay = min(self.vib_delay_hi, round(self.vib_delay + self.vib_delay_step, 3))
            self.vib_changed.set()
            self.save()

    def vib_delay_down(self):
        with self.lock:
            self.vib_delay = max(self.vib_delay_lo, round(self.vib_delay - self.vib_delay_step, 3))
            self.vib_changed.set()
            self.save()

    def faster(self):
        with self.lock:
            self.beat_t = max(self.lo, round(self.beat_t - self.step, 3))
            self.changed.set()
            self.save()

    def slower(self):
        with self.lock:
            self.beat_t = min(self.hi, round(self.beat_t + self.step, 3))
            self.changed.set()
            self.save()

    def get(self):
        with self.lock:
            return self.beat_t

    def consume_change(self):
        return self.changed.is_set()

    def clear_change(self):
        self.changed.clear()


def keyboard_thread(selector, tempo):
    """独立线程监听键盘. n/b 切歌, ./, 调速, q 退出."""
    while not selector._stop:
        if msvcrt and msvcrt.kbhit():
            ch = msvcrt.getch()
            if ch in (b'n', b'N'):
                selector.next()
                print("\n>>> [下一首]", flush=True)
            elif ch in (b'b', b'B'):
                selector.prev()
                print("\n>>> [上一首]", flush=True)
            elif ch == b'.':   # 加速
                tempo.faster()
                print(f"\n>>> [加速] beat_t={tempo.get():.3f}s", flush=True)
            elif ch == b',':   # 减速
                tempo.slower()
                print(f"\n>>> [减速] beat_t={tempo.get():.3f}s", flush=True)
            elif ch in (b'v', b'V'):   # 颤音开关
                tempo.toggle_vibrato()
                print(f"\n>>> [颤音] {'开' if tempo.vib_enabled else '关'}", flush=True)
            elif ch == b';':           # 颤音频率+
                tempo.vib_rate_up()
                print(f"\n>>> [颤音频率] {tempo.vib_rate:.1f}Hz", flush=True)
            elif ch == b"'":           # 颤音频率-
                tempo.vib_rate_down()
                print(f"\n>>> [颤音频率] {tempo.vib_rate:.1f}Hz", flush=True)
            elif ch == b']':           # 颤音幅度+
                tempo.vib_amp_up()
                print(f"\n>>> [颤音幅度] period×{tempo.vib_amp_frac:.4f}", flush=True)
            elif ch == b'[':           # 颤音幅度-
                tempo.vib_amp_down()
                print(f"\n>>> [颤音幅度] period×{tempo.vib_amp_frac:.4f}", flush=True)
            elif ch == b'-':           # 颤音延迟-
                tempo.vib_delay_down()
                print(f"\n>>> [颤音延迟] {tempo.vib_delay:.3f}s", flush=True)
            elif ch == b'=':           # 颤音延迟+
                tempo.vib_delay_up()
                print(f"\n>>> [颤音延迟] {tempo.vib_delay:.3f}s", flush=True)
            elif ch in (b'q', b'Q', b'\x1b'):   # q/ESC 退出
                selector.stop()
                print("\n>>> [退出]", flush=True)
                return
        time.sleep(0.02)


# ============== 播放 ==============
def play_note_env(voice, freq, dur):
    """一个音: keyon 持续 dur 秒 (Sustain 段), keyoff 后 Release."""
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


def play_song(psg, voice, name, base_octave, notes, selector, tempo):
    """播放一首歌. 若中途 selector 被切换则立即返回 (打断).
    切歌打断时复位硬件 + 音量清零.
    每个音前检查 tempo 变化, 同步给 voice (包络 D/R 缩放)."""
    beat_t = tempo.get()
    print(f"\n♪ {name} ♪  (beat_t={beat_t:.3f}s)", flush=True)
    for item in notes:
        # 键盘切换检查 (每个音前)
        if selector.consume_change():
            selector.clear_change()
            voice.silence()
            psg.volume(0)   # 切歌音量清零 (配合 RST)
            psg.reset()     # 切歌复位: 清计数器/toggle
            return False    # 被打断
        # 速度变化检查 → 同步包络
        if tempo.consume_change():
            tempo.clear_change()
            beat_t = tempo.get()
            voice.set_tempo(beat_t)
            print(f"\n   [速度更新] beat_t={beat_t:.3f}s", flush=True)
        # 颤音开关/频率/幅度/延迟变化检查 → 同步 voice
        if tempo.vib_changed.is_set():
            tempo.vib_changed.clear()
            voice.set_vibrato(tempo.vib_enabled, tempo.vib_rate, tempo.vib_amp_frac, tempo.vib_delay)
        if len(item) == 3:
            degree, beats, oct_override = item
            oct_use = oct_override[0]
        else:
            degree, beats = item
            oct_use = base_octave
        dur = beats * beat_t
        if degree == 0:
            voice.silence()
            n = int(dur / TICK)
            for _ in range(n):
                time.sleep(TICK)
        else:
            f = jianpu_freq(degree, oct_use)
            play_note_env(voice, f, dur)
    time.sleep(0.3)
    return True   # 正常播完


def main():
    import argparse
    parser = argparse.ArgumentParser(description='PSG v0.2 ADSR 合成器')
    parser.add_argument('--song', type=int, default=None,
                        help='只播放指定曲目 (1-N) 无限循环, 不指定则循环全部')
    args = parser.parse_args()

    songs = load_songs()
    if not songs:
        print("无曲目, 请检查 psg_songs.ini")
        return
    print(f"(已加载 {len(songs)} 首曲目: {', '.join(s[0] for s in songs)})")

    # --song 锁定单曲: 校验范围, 设定起始索引 + 锁定标志
    single_song = None
    start_idx = 0
    if args.song is not None:
        if not (1 <= args.song <= len(songs)):
            print(f"错误: --song 范围 1-{len(songs)}, 你给的是 {args.song}")
            return
        single_song = args.song - 1   # 0-indexed
        start_idx = single_song
        print(f"(单曲循环模式: 只播 #{args.song} {songs[single_song][0]})")

    psg = Psg()
    voice = Voice(psg)
    selector = SongSelector(len(songs))
    selector.idx = start_idx
    tempo = TempoControl()   # 从 ini 读上次速度 + 颤音开关
    voice.set_tempo(tempo.get())
    voice.set_vibrato(tempo.vib_enabled, tempo.vib_rate, tempo.vib_amp_frac, tempo.vib_delay)
    kb = threading.Thread(target=keyboard_thread, args=(selector, tempo), daemon=True)
    kb.start()

    print("=== PSG v0.2 ADSR 合成器 — 7 首曲目 ===")
    print("    键盘: n/b 切歌  ./, 速度  v 颤音开关  ;/' 颤音频率  [/] 颤音幅度  -/= 颤音延迟  q 退出")
    if single_song is not None:
        print(f"    单曲循环: #{args.song} (n/b 仍可切到其它曲, 但播完后回到 #{args.song})")
    else:
        print("    不操作则自动循环全部曲目")
    print(f"    初始 beat_t={tempo.get():.3f}s  颤音:{'开' if tempo.vib_enabled else '关'} {tempo.vib_rate:.1f}Hz 幅度×{tempo.vib_amp_frac:.4f} 延迟{tempo.vib_delay:.2f}s (从 ini 读取)")
    print(f"    ADSR: A{A_MS}ms D{D_MS}ms(随速度) S={S_LEVEL} R{R_MS}ms(随速度)\n")

    try:
        while not selector._stop:
            idx = selector.get()
            name, oct, notes = songs[idx]
            psg.reset()        # 每首歌开始前复位
            voice.silence()
            psg.volume(0)      # 音量清零
            print(f"\n########## 曲目 {idx+1}/{len(songs)} ##########", flush=True)
            selector.clear_change()
            tempo.clear_change()
            finished = play_song(psg, voice, name, oct, notes, selector, tempo)
            if not finished:
                continue   # 被键盘打断, 跳到新曲目
            # 正常播完: 单曲模式回到锁定曲目, 否则自动下一首
            if single_song is not None:
                with selector.lock:
                    selector.idx = single_song
            else:
                selector.next()
            selector.clear_change()
    except KeyboardInterrupt:
        print("\n停止")
    finally:
        selector.stop()
        voice.silence()
        psg._sd(BIT_RST, 0)   # 退出: RST 永远拉低 (持续复位=静音)
        psg.close()
        print("已静音, 设备关闭")

if __name__ == '__main__':
    main()
