"""gen_wt3_wavetable.py — 生成 4KB wavetable ROM

ROM 布局: 16 个音量级别 × 256 字节 sine
地址: A[11:8] = volume (4-bit), A[7:0] = phase (8-bit)
公式: sine[idx, vol] = round(128 + (sine_full[idx] - 128) * (vol / 15))
"""

import math

VOL_BITS = 4
VOL_LEVELS = 1 << VOL_BITS  # 16
PHASE_BITS = 8
PHASE_SIZE = 1 << PHASE_BITS  # 256

ROM_SIZE = VOL_LEVELS * PHASE_SIZE  # 4096

def sine_full(idx):
    """8-bit unsigned sine, 中心 0x80, 振幅 ±127"""
    return int(round(128 + 127 * math.sin(2 * math.pi * idx / PHASE_SIZE)))

def sine_with_vol(idx, vol):
    """按音量缩放"""
    full = sine_full(idx)
    val = round(128 + (full - 128) * (vol / (VOL_LEVELS - 1)))
    return max(0, min(255, val))

def main():
    rom = bytearray(ROM_SIZE)
    for vol in range(VOL_LEVELS):
        for idx in range(PHASE_SIZE):
            addr = (vol << PHASE_BITS) | idx
            rom[addr] = sine_with_vol(idx, vol)

    out_path = "rom/wt3_wavetable.hex"
    with open(out_path, "w") as f:
        for byte in rom:
            f.write(f"{byte:02X}\n")

    print(f"Generated {out_path}: {ROM_SIZE} bytes ({VOL_LEVELS} vols × {PHASE_SIZE} sine)")
    print(f"Sample values:")
    print(f"  vol=0  idx=0:   0x{rom[0]:02X}  (静音, 中点)")
    print(f"  vol=0  idx=64:  0x{rom[64]:02X}  (静音, 中点)")
    print(f"  vol=15 idx=0:   0x{rom[15*256+0]:02X}  (满档, sine[0]=128)")
    print(f"  vol=15 idx=64:  0x{rom[15*256+64]:02X}  (满档, sine 峰值 255)")
    print(f"  vol=15 idx=192: 0x{rom[15*256+192]:02X} (满档, sine 谷值 1)")
    print(f"  vol=8  idx=64:  0x{rom[8*256+64]:02X}  (半档, sine 峰值)")

if __name__ == "__main__":
    main()
