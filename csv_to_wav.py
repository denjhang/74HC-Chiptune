import struct, wave, sys

csv_path = sys.argv[1] if len(sys.argv) > 1 else "wt_output.csv"
wav_path = csv_path.replace(".csv", ".wav")

samples = []
with open(csv_path) as f:
    next(f)  # skip header
    for line in f:
        parts = line.strip().split(",")
        if len(parts) == 2:
            samples.append(int(parts[1]))

# 8-bit signed → unsigned for WAV
raw = bytearray()
for s in samples:
    raw.append((s + 128) & 0xFF)

# 采样率约 32KHz
sr = 32051

with wave.open(wav_path, "w") as wf:
    wf.setnchannels(1)
    wf.setsampwidth(1)
    wf.setframerate(sr)
    wf.writeframes(bytes(raw))

print(f"WAV: {wav_path}  samples={len(samples)}  duration={len(samples)/sr:.2f}s  sr={sr}")
