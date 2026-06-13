#!/usr/bin/env python3
# top2wav.py — wt_top_output.csv → WAV
#
# 输入: sample,dac (8-bit unsigned mixed)
# 输出: 16-bit mono WAV
# 采样率: 96000 Hz (3.072MHz / 32, 与 WSG 一致)

import csv
import wave
import struct
import os
import sys

SAMPLE_RATE = 96000

# 项目根目录 (rom/ 的上一级)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def main():
    samples = []
    csv_path = os.path.join(ROOT, "wt_top_output.csv")
    with open(csv_path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            dac = int(row["dac"])  # 0-240
            # 0-240 8-bit unsigned → -32768~32767 signed
            # center = 120
            s16 = int((dac - 120) * 32767 / 120)
            s16 = max(-32768, min(32767, s16))
            samples.append(s16)

    wav_path = os.path.join(ROOT, "wt_top_output.wav")
    with wave.open(wav_path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        for s in samples:
            w.writeframes(struct.pack("<h", s))

    print(f"Written {len(samples)} samples to wt_top_output.wav")
    print(f"Duration: {len(samples)/SAMPLE_RATE*1000:.2f} ms")

if __name__ == "__main__":
    main()
