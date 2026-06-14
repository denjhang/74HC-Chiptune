import struct, wave, sys

csv_path = sys.argv[1] if len(sys.argv) > 1 else "wt3_sine.csv"
wav_path = csv_path.replace(".csv", ".wav")

samples = []
with open(csv_path) as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                samples.append(int(line))
            except ValueError:
                pass  # skip header

# dac_out 是 8-bit unsigned (0-255, sine 表中心 128)
# 直接写入 unsigned 8-bit
raw = bytearray()
for s in samples:
    raw.append(s & 0xFF)

# 采样率 96kHz (每个 latch_dac_clk 一个样本, 32 step 周期 = 96kHz)
sr = 96000

with wave.open(wav_path, "w") as wf:
    wf.setnchannels(1)
    wf.setsampwidth(1)
    wf.setframerate(sr)
    wf.writeframes(bytes(raw))

print(f"WAV: {wav_path}  samples={len(samples)}  duration={len(samples)/sr:.3f}s  sr={sr}Hz")
