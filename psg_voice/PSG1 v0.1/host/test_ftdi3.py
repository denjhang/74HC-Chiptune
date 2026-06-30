#!/usr/bin/env python3
# test_ftdi3.py — 测试 FT232H 能否切 MPSSE 模式 (决定引脚方案)
import ftd2xx

dev = ftd2xx.open(0)
dev.resetDevice()

# 0x02 = MPSSE 模式, direction 0x00 (先全输入测试能否切换)
try:
    dev.setBitMode(0x00, 0x02)
    print("[OK] MPSSE 模式切换成功")
    print(">>> 可以用 ACBUS C0-C7 (8 GPIO) + ADBus D4-D7 (4 GPIO) = 12 GPIO")
    print(">>> PSG 的 11 个 GPIO 完全够用, 且不用加 HC595 <<<")
except ftd2xx.DeviceError as e:
    print(f"[FAIL] MPSSE 切换失败: {e}")
    print("只能用 async bitbang (ADBus D0-D7, 8 个), 需要加 HC595 扩展")

dev.close()
