#!/usr/bin/env python3
# csv2wav_top.py — wt_top_output.csv → WAV (3 voice 混音)
# 输入: sample,v0,v1,v2 (每个 8-bit, 0-225, 中心 ~112)
# 输出: 16-bit mono WAV, 3 voice 平均混音

import csv
import wave
import struct
import sys

csv.field_size_limit(2**24)  # 16MB, 够用且不溢出
SAMPLE_RATE = 96000

def main():
    samples = []
    with open("wt_top_output.csv", "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if not row.get("v0") or not row.get("v1") or not row.get("v2"):
                continue
            try:
                v0 = int(row["v0"]); v1 = int(row["v1"]); v2 = int(row["v2"])
            except (ValueError, KeyError, TypeError):
                continue
            # 3 voice 取平均, 0-225 → -32768..32767
            mix = (v0 + v1 + v2) / 3.0
            sample16 = int((mix - 112.5) * 32767 / 112.5)
            sample16 = max(-32768, min(32767, sample16))
            samples.append(sample16)

    with wave.open("wt_top_output.wav", "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        for s in samples:
            w.writeframes(struct.pack("<h", s))

    print(f"Written {len(samples)} samples to wt_top_output.wav")
    print(f"Duration: {len(samples)/SAMPLE_RATE:.3f} sec")

if __name__ == "__main__":
    main()
