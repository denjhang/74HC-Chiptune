#!/usr/bin/env python3
# gen_rev_e3_rom.py — PSG3 v0.5 rev.e3 PCM-only ROM 生成
#
# rev.e3 = PCM 专用, 无波形. 每槽 8K 全填 PCM, 无限循环.
# 输出: rev_e3_rom.bin (128K, 烧 SST39SF010)
#
# 16 槽分配 (sel 0-15 → A13-16):
#   0x00-0x05: 鼓组 (BD/SD/HH/TOM/RIM/TOP)
#   0x06-0x0F: 乐器 (Piano/SlapBass/Oboe/Trumpet/Strings/Harp/Guitar/Shakuhachi/Blow/Oboe2)
#
# 所有采样重采样到 8kHz, 8-bit 无符号 (128=静音), crossfade 无缝循环.

import sys
import wave
import os
import struct

SLOT_SIZE = 8192      # 每槽 8K
NUM_SLOTS = 16        # 16 槽
TARGET_RATE = 8000    # PCM 重采样到 8kHz


def clamp(v, lo=0, hi=255):
    return max(lo, min(hi, int(round(v))))


PCM_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'pcm')

# 16 个 PCM 源 (sel 0-15), 全部循环
PCM_SOURCES = [
    ('drum/2608_BD.WAV',      'BD (底鼓)'),
    ('drum/2608_SD.WAV',      'SD (军鼓)'),
    ('drum/2608_HH.WAV',      'HH (踩镲)'),
    ('drum/2608_TOM.WAV',     'TOM (嗵鼓)'),
    ('drum/2608_RIM.WAV',     'RIM (边击)'),
    ('drum/2608_TOP.WAV',     'TOP (踩镲开)'),
    ('ins/01_piano.wav',      'Piano (钢琴)'),
    ('ins/02_slapbass.wav',   'SlapBass (贝斯)'),
    ('ins/04_oboe.wav',       'Oboe (双簧管)'),
    ('ins/05_trumpet.wav',    'Trumpet (小号)'),
    ('ins/08_strings.wav',    'Strings (弦乐)'),
    ('ins/09_harp.wav',       'Harp (竖琴)'),
    ('ins/10_guitar.wav',     'Guitar (吉他)'),
    ('ins/03_shakuhachi.wav', 'Shakuhachi (尺八)'),
    ('ins/06_blow.wav',       'Blow (吹管)'),
    ('ins/07_oboe2.wav',      'Oboe2'),
]


def load_wav_pcm(filepath, target_rate=TARGET_RATE, target_len=SLOT_SIZE, gain=1.0):
    """加载 WAV, 重采样到 target_rate, 归一化后 ×gain, 转 8-bit (clip), crossfade 循环."""
    w = wave.open(filepath)
    rate = w.getframerate()
    n_channels = w.getnchannels()
    sampwidth = w.getsampwidth()
    n_frames = w.getnframes()
    raw = w.readframes(n_frames)
    w.close()

    # 解码 → float (-1..1)
    if sampwidth == 2:
        samples = list(struct.unpack(f'<{n_frames}h', raw))
    elif sampwidth == 1:
        samples = [s - 128 for s in struct.unpack(f'<{n_frames}B', raw)]
    else:
        samples = [0] * n_frames

    # 多声道取第 0 声道
    if n_channels > 1:
        samples = samples[::n_channels]

    # 重采样 (线性插值)
    ratio = target_rate / rate
    new_len = int(len(samples) * ratio)
    resampled = []
    for i in range(new_len):
        src_pos = i / ratio
        idx0 = int(src_pos)
        idx1 = min(idx0 + 1, len(samples) - 1)
        frac = src_pos - idx0
        val = samples[idx0] * (1 - frac) + samples[idx1] * frac
        resampled.append(val)

    # 归一化 → 8-bit 无符号 (128=静音), 再 ×gain (clip 到 0-255)
    max_abs = max(abs(v) for v in resampled) if resampled else 1
    if max_abs == 0:
        max_abs = 1
    pcm = [clamp(128 + 127 * gain * v / max_abs) for v in resampled]

    # crossfade 首尾 (无缝循环)
    if len(pcm) > 200:
        cf_len = min(128, len(pcm) // 4)
        for i in range(cf_len):
            fade_out = (cf_len - i) / cf_len
            fade_in = i / cf_len
            pcm[i] = clamp(pcm[i] * fade_out + pcm[-cf_len + i] * fade_in)
        pcm = pcm[:-cf_len]

    # 截断/填充到 target_len
    if len(pcm) >= target_len:
        pcm = pcm[:target_len]
    else:
        pcm = pcm + [128] * (target_len - len(pcm))

    return pcm


def build_rom(gain=1.0):
    rom = bytearray(SLOT_SIZE * NUM_SLOTS)   # 128K

    for slot in range(NUM_SLOTS):
        base = slot * SLOT_SIZE
        pcm_file, pcm_name = PCM_SOURCES[slot]
        pcm_path = os.path.join(PCM_DIR, pcm_file)
        if os.path.exists(pcm_path):
            pcm = load_wav_pcm(pcm_path, TARGET_RATE, SLOT_SIZE, gain=gain)
            for i in range(SLOT_SIZE):
                rom[base + i] = pcm[i]
            print(f'槽 {slot:2d} (0x{slot:02X}) {pcm_name:20s}: {os.path.basename(pcm_file)}')
        else:
            print(f'槽 {slot:2d}: 文件不存在 {pcm_path}', file=sys.stderr)

    return rom


def write_bin(rom, filename):
    with open(filename, 'wb') as f:
        f.write(bytes(rom))
    print(f'\n生成 {filename}: {len(rom)} 字节 (128K, SST39SF010)')
    print('烧录: TL866 选 SST39SF010, 加载 .bin, 全片写入.')


def main():
    # 用法: gen_rev_e3_rom.py [输出文件] [增益倍数]
    #   默认: rev_e3_rom.bin 1.0x
    #   例:   gen_rev_e3_rom.py rev_e3_rom_4x.bin 4
    out_file = sys.argv[1] if len(sys.argv) > 1 else 'rev_e3_rom.bin'
    gain = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
    print(f'增益: {gain}x')
    rom = build_rom(gain=gain)
    write_bin(rom, out_file)


if __name__ == '__main__':
    main()
