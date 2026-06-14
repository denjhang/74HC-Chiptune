#!/usr/bin/env python3
# pack_v14.py — 打包 v1.4 4 通道钢琴包络级联版本
import os, zipfile

ROOT = r"D:\working\vscode-projects\74HC-Chiptune"
OUT = os.path.join(ROOT, "wt3_wsg_v1.4_piano_cascade.zip")

FILES = [
    "rtl/wt3_core.v",
    "rtl/wt3_spfm_bus.v",
    "rtl/hc154.v",
    "rtl/hc157.v",
    "rtl/hc161.v",
    "rtl/hc273.v",
    "rtl/hc283.v",
    "rtl/hc373.v",
    "rtl/hc174.v",
    "rtl/hc377.v",
    "rtl/hc39sf040.v",
    "rtl/hc62256.v",
    "tb/wt3_core_tb.v",
    "rom/wt3_microcode.hex",
    "rom/wt3_wavetable.hex",
    "rom/gen_wt3_microcode.py",
    "rom/gen_wt3_wavetable.py",
    "rom/wt3_csv2wav.py",
    "docs/wt3-architecture.md",
    "docs/cmos-synth-3786.md",
    "docs/hc-chiptune-design.md",
    "docs/wiring-table.md",
    "build_wt3.sh",
]

with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
    for rel in FILES:
        abs_p = os.path.join(ROOT, rel.replace("/", os.sep))
        if not os.path.exists(abs_p):
            print(f"MISS: {rel}")
            continue
        # 保留相对路径结构
        arcname = rel
        z.write(abs_p, arcname)
        print(f"  + {arcname}")

print(f"\nCreated: {OUT}")
print(f"Size: {os.path.getsize(OUT)} bytes")
