#!/usr/bin/env python3
# csv2wav.py — 把 wsg3_dac.csv (8-bit dac_out 序列) 转成 WAV
#
# WSG3 DAC 输出是 wave_nib * vol_nib, 范围 0~225 (单极性, 模拟 R-2R ladder 0~VCC).
# 映射到 16-bit 有符号: 居中到 0, 最大幅值 ±32767.
#
# 采样率: 96 kHz (Pac-Man 原版, 3.072MHz / 32)

import sys
import wave
import struct

SAMPLE_RATE = 96000
DAC_MAX = 225  # wave(15) * vol(15) = 225

def main(csv_path, wav_path):
    samples = []
    with open(csv_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            samples.append(int(line))

    if not samples:
        print(f"ERROR: no samples in {csv_path}")
        sys.exit(1)

    s_min = min(samples)
    s_max = max(samples)
    s_center = (s_max + s_min) // 2
    s_amp = max(s_max - s_center, s_center - s_min, 1)

    print(f"Sample range: {s_min}~{s_max}, center={s_center}, amp={s_amp}")
    print(f"Total: {len(samples)} samples, duration: {len(samples)/SAMPLE_RATE:.3f} sec")

    with wave.open(wav_path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        for s in samples:
            # 居中并归一化到 ±32767
            sample16 = ((s - s_center) * 32767) // s_amp
            sample16 = max(-32768, min(32767, sample16))
            w.writeframes(struct.pack("<h", sample16))

    print(f"Written {len(samples)} samples to {wav_path}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} input.csv output.wav")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])

