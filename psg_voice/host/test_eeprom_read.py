#!/usr/bin/env python3
# test_eeprom_read.py — 读 FT232H EEPROM, 看 CBUS 引脚当前配置
#
# FT232H EEPROM 关键字段 (字节偏移):
#   0x14: CBUS_FUNCTION_0 (C0 功能)
#   0x15: CBUS_FUNCTION_1 (C1)
#   0x16: CBUS_FUNCTION_2 (C2)  <- 通常作 CLKOUT 的脚
#   0x17: CBUS_FUNCTION_3 (C3)
#   0x18: CBUS_FUNCTION_4 (C4)
#   0x19: CBUS_FUNCTION_5 (C5)
#   0x1A: CBUS_FUNCTION_6 (C6)
#   0x1B: CBUS_FUNCTION_7 (C7)
#   (C8/C9 在 FT232H 由 ACBUS 配置, 不是这 8 个字节)
#
# CBUS 功能码 (FT232H):
#   0x00 = TRISTATE
#   0x01 = RXLED
#   0x02 = TXLED
#   0x04 = TXDEN
#   0x05 = PWREN
#   0x08 = SLEEP
#   0x09 = DRIVE_0 (驱动低)
#   0x0A = DRIVE_1 (驱动高)
#   0x0B = GPIO (普通输入)
#   0x0C = GPIO_OUTPUT (普通输出)
#   0x1D = CLK30 (30MHz)  <- 各档 CLKOUT
#   0x1E = CLK15
#   0x1F = CLK7_5
#   注: 不同 datasheet 档位码略有差异, 以实测为准

import ftd2xx
import time

CBUS_NAMES = {
    0x00: "TRISTATE", 0x01: "RXLED", 0x02: "TXLED", 0x04: "TXDEN",
    0x05: "PWREN", 0x08: "SLEEP", 0x09: "DRIVE0", 0x0A: "DRIVE1",
    0x0B: "GPIO_IN", 0x0C: "GPIO_OUT",
    0x1D: "CLK30M", 0x1E: "CLK15M", 0x1F: "CLK7.5M",
    # FT232H 特有的 CLKOUT 档位 (部分文档):
    0x10: "CLK12M", 0x11: "CLK6M", 0x12: "CLK3M",
    0x13: "CLK1.5M", 0x14: "CLK750k", 0x15: "CLK375k",
}

def main():
    print("=== 读 FT232H EEPROM ===\n")
    dev = ftd2xx.open(0)
    dev.resetDevice()

    # 读 EEPROM (FT_EE_Read 通过 ProgramData)
    try:
        data = dev.readEEPROM(0, 256)  # 读 0-255 字节
    except Exception as e:
        print(f"读 EEPROM 失败: {e}")
        # 试小块读
        data = bytearray()
        for addr in range(0, 256, 2):
            try:
                word = dev.readEEPROM(addr)  # 某些版本按 word 读
                data.extend([word & 0xFF, (word >> 8) & 0xFF])
            except Exception as e2:
                print(f"  addr {addr}: {e2}")
                break
        if not data:
            dev.close()
            return

    dev.close()

    # 打印全部内容 (hex dump)
    print("EEPROM 内容 (前 64 字节):")
    for i in range(0, min(64, len(data)), 16):
        hexs = " ".join(f"{data[i+j]:02x}" for j in range(min(16, len(data)-i)))
        print(f"  {i:04x}: {hexs}")

    # 解析 CBUS 功能
    print("\nCBUS 引脚配置:")
    for cbus_idx in range(8):
        addr = 0x14 + cbus_idx
        if addr < len(data):
            val = data[addr]
            name = CBUS_NAMES.get(val, f"UNKNOWN(0x{val:02x})")
            print(f"  C{cbus_idx} (offset 0x{addr:02x}) = 0x{val:02x} -> {name}")

    # 关键: VID/PID
    if len(data) >= 4:
        vid = data[0x02] | (data[0x03] << 8)
        pid = data[0x00] | (data[0x01] << 8)
        print(f"\nVID:PID = {vid:04x}:{pid:04x}")

if __name__ == '__main__':
    main()
