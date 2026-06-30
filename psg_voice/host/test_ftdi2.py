#!/usr/bin/env python3
# test_ftdi2.py — 用 ftd2xx 库打开 FT232H 并测试 GPIO
import ftd2xx
import time

print("=== FT232H D2XX 测试 ===")

# 1. 创建设备列表
n = ftd2xx.createDeviceInfoList()
print(f"找到 {n} 个 FTDI 设备")

# 2. 打开设备 (索引 0)
try:
    dev = ftd2xx.open(0)
    print(f"[OK] 设备已打开")
except ftd2xx.DeviceError as e:
    print(f"[FAIL] 打开失败: {e}")
    print("\n说明: 设备被 COM3 串口或其他进程占用.")
    print("解决: 关闭所有占用 COM3 的程序 (串口调试工具/终端/Arduino IDE)")
    print("      或在设备管理器把 FT232H 的驱动从 VCP 改成 D2XX-only")
    raise SystemExit(1)

# 3. 配置成 MPSSE 模式前的基本设置
dev.resetDevice()
dev.setBaudRate(100000)  # MPSSE 用, 实际由时钟分频决定
print("[OK] 设备已 reset 并配置")

# 4. 读取当前 GPIO 状态 (用 FT_GetBitMode 看引脚)
try:
    mode = dev.getBitMode()
    print(f"[OK] 当前 bit mode 值: 0x{mode:02x}")
except Exception as e:
    print(f"bit mode 读取: {e}")

# 5. 切到 bitbang 模式 (0x01 = async bitbang, 可测 GPIO)
try:
    dev.setBitMode(0x00, 0x00)  # 先 reset 模式
    dev.setBitMode(0xFF, 0x01)  # 全输出, async bitbang
    print("[OK] 已切到 async bitbang 模式 (8 位输出)")
    print(">>> FT232H GPIO 可用! 可以驱动 PSG <<<")
except ftd2xx.DeviceError as e:
    print(f"[FAIL] 切 bitbang 失败: {e}")

dev.close()
print("\n设备已关闭, 测试完成")
