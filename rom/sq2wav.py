#!/usr/bin/env python3
# sq2wav.py — sq_output.csv → WAV (快速版)
# 直接构造 bytes 一次写入, 不用循环 writeframes

import csv
import wave
import struct

SAMPLE_RATE = 1789773

def main():
    high = struct.pack("<h", 32767)
    low  = struct.pack("<h", -32768)

    chunks = []
    with open("sq_output.csv", "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            v = row.get("sq_out")
            if v is None or v == "x":
                continue
            try:
                bit = int(v)
            except ValueError:
                continue
            chunks.append(high if bit else low)

    data = b"".join(chunks)

    with wave.open("sq_output.wav", "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(data)

    print(f"Written {len(chunks)} samples to sq_output.wav")
    print(f"Sample rate: {SAMPLE_RATE} Hz")
    print(f"Duration: {len(chunks)/SAMPLE_RATE:.4f} sec")

if __name__ == "__main__":
    main()
