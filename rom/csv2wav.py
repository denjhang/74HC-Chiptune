#!/usr/bin/env python3
# csv2wav.py — 把 wt_synth_output.csv 转成 WAV
#
# 输入: sample,v1,v2,v3 (8-bit unsigned per voice)
# 输出: 16-bit mono WAV, 3 voices 混音
#
# 采样率: 96000 Hz (Pac-Man 原版)

import csv
import wave
import struct

SAMPLE_RATE = 96000

def main():
    samples = []
    with open("wt_synth_output.csv", "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            v1 = int(row["v1"])
            v2 = int(row["v2"])
            v3 = int(row["v3"])
            # 混音: 3 个 0-225 的值相加, 范围 0-675
            # 缩放到 0-65535 (16-bit)
            mix = v1 + v2 + v3  # 0-675
            # 映射到 16-bit signed (-32768 ~ 32767)
            # 中心 337.5 → 0
            sample16 = int((mix - 337.5) * 32767 / 337.5)
            sample16 = max(-32768, min(32767, sample16))
            samples.append(sample16)

    with wave.open("wt_synth_output.wav", "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)  # 16-bit
        w.setframerate(SAMPLE_RATE)
        for s in samples:
            w.writeframes(struct.pack("<h", s))

    print(f"Written {len(samples)} samples to wt_synth_output.wav")
    print(f"Duration: {len(samples)/SAMPLE_RATE:.3f} sec")

if __name__ == "__main__":
    main()
