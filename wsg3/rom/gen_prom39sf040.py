#!/usr/bin/env python3
# gen_prom39sf040.py
#
# 把原版 Pac-Man WSG 的两片 82S126 (256×4 PROM) 数据
# 适配到 39SF040 (512KB Flash) 的 hex 格式。
#
# 策略:
#   82S126 数据是 4-bit nibble, 文件里每个字节就是 1 个 nibble (0x00-0x0F)
#   39SF040 是 8-bit, 我们直接 1:1 复制, 数据放在低 4 位, 高 4 位填 0
#   这样地址映射 1:1, 读出来后用 & 0x0F 取低 4 位即可
#
#   总共 524288 字节, 前 256 字节放原数据, 后面全填 0x00
#
# 输出:
#   rom/wsg3_prom3m.hex  (来自 82s126.3m)
#   rom/wsg3_prom1m.hex  (来自 82s126.1m)

import sys
from pathlib import Path

SRC_DIR = Path(r"D:\working\vscode-projects\74HC-Chiptune\reference\Namco WSG\rom")
DST_DIR = Path(r"D:\working\vscode-projects\74HC-Chiptune\rom")

ROM_SIZE = 512 * 1024  # 39SF040 = 4Mbit = 512KB

def convert(src_bin: Path, dst_hex: Path):
    data = src_bin.read_bytes()
    if len(data) != 256:
        print(f"WARN: {src_bin.name} size = {len(data)}, expected 256")

    rom = bytearray(ROM_SIZE)
    for i, b in enumerate(data):
        rom[i] = b & 0x0F  # 只保留低 4 位 (保险)

    with open(dst_hex, "w") as f:
        for b in rom:
            f.write(f"{b:02X}\n")

    # 摘要: 列前 16 个非零字节
    nonzero = [(i, rom[i]) for i in range(256) if rom[i] != 0]
    print(f"{src_bin.name} -> {dst_hex.name}")
    print(f"  size: {ROM_SIZE} bytes")
    print(f"  source data bytes: {len(data)}")
    print(f"  non-zero entries in first 256: {len(nonzero)}")
    print(f"  first 16 non-zero: {[(hex(i), hex(v)) for i, v in nonzero[:16]]}")
    print()

if __name__ == "__main__":
    DST_DIR.mkdir(exist_ok=True)
    convert(SRC_DIR / "82s126.3m", DST_DIR / "wsg3_prom3m.hex")
    convert(SRC_DIR / "82s126.1m", DST_DIR / "wsg3_prom1m.hex")
    print("Done.")
