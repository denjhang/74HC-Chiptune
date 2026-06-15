#!/usr/bin/env python3
# gen_prom1m.py — 生成 1M 波形 ROM (39SF040 512KB)
#
# 数据源: reference/Namco WSG/rom/82s126.1m (256 字节 BIN, 8 波 × 32 样本 × 4-bit/byte)
#
# 地址布局 (Pac-Man 原版):
#   addr[2:0] = 波形号 (0-7)
#   addr[7:3] = 相位 (0-31)
# 即: addr = (wave_sel << 5) | phase_sel
#
# 这与 82s126.1m BIN 文件的物理布局完全一致 (前 32 字节 = 波形 0, ...).
# 因此直接把 BIN 复制到 hex, 其余 512KB-256 字节填 0xFF.

ROM_SIZE = 512 * 1024  # 39SF040 = 512KB
SRC_FILE = "../../reference/Namco WSG/rom/82s126.1m"

src = open(SRC_FILE, "rb").read()
print(f"Source: {SRC_FILE} ({len(src)} bytes)")

assert len(src) == 256, f"Expected 256 bytes, got {len(src)}"

# 填充到 512KB
rom = bytearray([0xFF] * ROM_SIZE)
rom[:256] = src

# 输出 hex 文件 (空格分隔, 小写, 多行换行避免单行过长)
with open("wsg3_prom1m.hex", "w", newline="\n") as f:
    for chunk_start in range(0, len(rom), 16):
        chunk = rom[chunk_start:chunk_start+16]
        f.write(" ".join(f"{b:02x}" for b in chunk) + "\n")

print(f"Generated wsg3_prom1m.hex ({ROM_SIZE} bytes)")

# 打印前 8 个波形 (每个 32 样本) 的概况
print("\nWaveform summary (8 waves × 32 samples):")
for w in range(8):
    samples = [src[w*32 + p] & 0x0F for p in range(32)]
    print(f"  Wave {w}: min={min(samples)} max={max(samples)} first 8 = {samples[:8]}")
