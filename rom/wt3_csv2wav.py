#!/usr/bin/env python3
# wt3_csv2wav.py — 把 wt3_sine.csv (TDM 4 通道交错 dac_out) 转成 WAV
#
# CSV 每行一个 8-bit dac_out, TDM 序列 (192kHz 全局采样率):
#   ch0, ch1, ch2, ch3, ch0, ch1, ch2, ch3, ...
# 这是 DAC 实际看到的电压序列, 直接 192kHz 单声道播放即可
# 听到的是 4 通道混合 (TDM DAC + 低通滤波 = 模拟混音)

import sys
import wave
import struct

SAMPLE_RATE = 192000  # TDM 全局采样率 (4 通道 × 48kHz)

def main(csv_path, wav_path):
    samples = []
    with open(csv_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            samples.append(int(line))

    with wave.open(wav_path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        for s in samples:
            sample16 = (s - 128) * 128
            sample16 = max(-32768, min(32767, sample16))
            w.writeframes(struct.pack("<h", sample16))

    print(f"Written {len(samples)} samples to {wav_path}")
    print(f"Duration: {len(samples)/SAMPLE_RATE:.3f} sec")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} input.csv output.wav")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])

