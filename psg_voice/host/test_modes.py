#!/usr/bin/env python3
# test_modes.py — 测试 FT232H 各模式下 GPIO 可用性
#
# 关键问题: 能否同时用 D0-D7 和 C0-C7?
# - MPSSE: D0-D3 被 SPI 占用, 但 C0-C7 可用
# - Bitbang: D0-D7 全可用, 但 C0-C7 通常不可用
# 本脚本实测两种模式, 报告每种模式实际能控哪些脚

import ftd2xx
import time

def test_mode(mode_name, mode_code, set_cbus_dir=False):
    """测试指定模式, 写每个脚高低并回读."""
    print(f"\n=== 模式: {mode_name} (0x{mode_code:02x}) ===")
    dev = ftd2xx.open(0)
    dev.resetDevice()
    try:
        # 全 D 口方向输出 (0xFF), 初始全 0
        dev.setBitMode(0x00, mode_code)
        time.sleep(0.05)
    except ftd2xx.DeviceError as e:
        print(f"  切换失败: {e}")
        dev.close()
        return

    results = []
    # 测 ADBus D0-D7
    for bit in range(8):
        name = f"D{bit}"
        # 写高
        dev.write(bytes([0x80, 1 << bit, 0xFF]))
        time.sleep(0.02)
        try:
            dev.purge(1); dev.write(bytes([0x81])); time.sleep(0.01)
            rh = dev.read(1)
            rh = rh[0] if isinstance(rh,(bytes,bytearray)) and len(rh) else -1
        except: rh = -1
        # 写低
        dev.write(bytes([0x80, 0x00, 0xFF]))
        time.sleep(0.02)
        try:
            dev.purge(1); dev.write(bytes([0x83 if False else 0x81])); time.sleep(0.01)
            rl = dev.read(1)
            rl = rl[0] if isinstance(rl,(bytes,bytearray)) and len(rl) else -1
        except: rl = -1
        ok = (rh>=0 and (rh>>bit)&1) and (rl>=0 and not ((rl>>bit)&1))
        results.append((name, ok, rh, rl))

    # 测 ACBUS C0-C7 (在 bitbang 模式可能读不到)
    for bit in range(8):
        name = f"C{bit}"
        dev.write(bytes([0x82, 1 << bit, 0xFF]))
        time.sleep(0.02)
        try:
            dev.purge(1); dev.write(bytes([0x83])); time.sleep(0.01)
            rh = dev.read(1)
            rh = rh[0] if isinstance(rh,(bytes,bytearray)) and len(rh) else -1
        except: rh = -1
        dev.write(bytes([0x82, 0x00, 0xFF]))
        time.sleep(0.02)
        try:
            dev.purge(1); dev.write(bytes([0x83])); time.sleep(0.01)
            rl = dev.read(1)
            rl = rl[0] if isinstance(rl,(bytes,bytearray)) and len(rl) else -1
        except: rl = -1
        ok = (rh>=0 and (rh>>bit)&1) and (rl>=0 and not ((rl>>bit)&1))
        results.append((name, ok, rh, rl))

    dev.write(bytes([0x80, 0x00, 0xFF]))
    dev.write(bytes([0x82, 0x00, 0xFF]))
    dev.close()

    d_ok = sum(1 for n,ok,_,_ in results if n.startswith('D') and ok)
    c_ok = sum(1 for n,ok,_,_ in results if n.startswith('C') and ok)
    print(f"  ADBus D0-D7: {d_ok}/8 可控")
    print(f"  ACBUS C0-C7: {c_ok}/8 可控")
    for name, ok, rh, rl in results:
        mark = "OK " if ok else "FAIL"
        h = f"0x{rh:02x}" if rh>=0 else "ERR"
        l = f"0x{rl:02x}" if rl>=0 else "ERR"
        print(f"    {name} [{mark}] H={h} L={l}")

# 测两种模式
test_mode("Async Bitbang", 0x01)
test_mode("MPSSE", 0x02)
