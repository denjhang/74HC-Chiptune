#!/usr/bin/env python3
# test_ftdi.py — 测试 FT232H 可用性 (D2XX 路线)
import ctypes
import sys

print(f"Python 位深: {sys.maxsize > 2**32 and '64' or '32'} bit")

# 1. 尝试加载 FTD2XX.dll
try:
    ftd = ctypes.windll.LoadLibrary("FTD2XX.dll")
    print("[OK] FTD2XX.dll 加载成功")
except Exception as e:
    print(f"[FAIL] FTD2XX.dll 加载失败: {e}")
    sys.exit(1)

# 2. 列出设备数
FT_CreateDeviceInfoList = ftd.FT_CreateDeviceInfoList
FT_CreateDeviceInfoList.restype = ctypes.c_long
numdevs = ctypes.c_long(0)
ret = FT_CreateDeviceInfoList(ctypes.byref(numdevs))
print(f"[{'OK' if ret==0 else 'FAIL'}] FT_CreateDeviceInfoList: ret={ret}, 找到 {numdevs.value} 个 FTDI 设备")

if numdevs.value == 0:
    print("\n说明: 设备存在但 D2XX 看不到它, 可能是 VCP(串口)模式独占.")
    print("需要在 FTDI 驱动里把设备切到 D2XX 模式 (非 VCP).")
    sys.exit(1)

# 3. 列设备信息
class FT_DEVICE_LIST_INFO_NODE(ctypes.Structure):
    _fields_ = [("Flags", ctypes.c_ulong),
                ("Type", ctypes.c_ulong),
                ("ID", ctypes.c_ulong),
                ("LocId", ctypes.c_ulong),
                ("SerialNumber", ctypes.c_char * 16),
                ("Description", ctypes.c_char * 64),
                ("FT_Handle", ctypes.c_void_p)]

FT_GetDeviceInfoList = ftd.FT_GetDeviceInfoList
devs = (FT_DEVICE_LIST_INFO_NODE * numdevs.value)()
ret = FT_GetDeviceInfoList(devs, ctypes.byref(numdevs))
print(f"\n设备列表:")
for i, d in enumerate(devs):
    print(f"  [{i}] Serial={d.SerialNumber.decode().strip()} "
          f"Desc={d.Description.decode().strip()} "
          f"ID=0x{d.ID:08x} Flags=0x{d.Flags:x}")

print("\n>>> FTD2XX 路线可用! 可以装 ftd2xx 库继续 <<<")
