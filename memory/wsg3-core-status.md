---
name: wsg3-core-status
description: wsg3_core.v 进度 - DAC 输出 283Hz (目标 440Hz, 慢 0.64x), 相位源待确定
metadata:
  type: project
---

## 当前状态 (2026-06-16)

**DAC 有输出，频率 ~283Hz，目标 A4=440Hz (慢 0.64x)**

测试 `wsg3/tb/wsg3_func_tb.v`:
- SPFM 写入 freq=0x012C6, vol=15, wave=0
- 50000 样本，40828 个非零 (81.7%)
- 边沿间隔: 128→320→576→128... 样本 (128=2 TDM 周期)
- 频率: 283Hz (期望 440Hz)

## 已修复 bug

1. **3M 微码 ROM nibble 顺序** - MSB-first (sub0=nibble[15:12])
   `gen_prom3m.py`: `nibble = (word >> (4 * (3 - sub))) & 0xF`
   生成器输出: step 0 = `1101 1110 1111 0111` (匹配文档)

2. **cp273 未定义** - 添加 `wire cp273 = ~cp273_pulse_n & SPFM_RST_n & ~spfm_write_active;`
   bit[2]=0 时 cp273=1 (上升沿锁存 U11 输出寄存器)

3. **X-propagation** (上一轮) - U6/U7 CS_n 始终为 0, WE_n 按 reg_addr[4] 区分

4. **cd4066 inout 反馈** (上一轮) - 单向驱动 IO_B

## 当前问题: 频率慢 0.64x

文档 line 212: `rom1m_addr[4:0] = sum_d_1L[4:0]` (即 carry_chain[4:0])

问题: carry_chain 是 6-bit 滑动窗，在 5 个 nibble 加法中更新 5 次（每次 clk174 滑动 1 bit）。
真正的 20-bit 累加器值分散在 U6[0..4] 中，但 TDM 只能每次读 1 个 nibble。

**待解**: 波形 ROM 地址应该用什么？
- 选项 A: carry_chain[4:0] (当前实现，283Hz)
- 选项 B: 从 acc RAM 组合的 20-bit 值 (需理解如何 latch 全 20-bit)

## 关键架构

- 14 IC: 3 SPFM + 11 WSG
- TDM 96kHz, HCNT 6-bit, 16 step × 4 sub-cycle
- ch0 用 5 nibble (20-bit freq), ch1/ch2 用 4 nibble (16-bit)
- 微码: 0xDEF7 (clear), 0xDEFF (write), 0xBFFF (output)

## 文件位置

- 主模块: `wsg3/rtl/wsg3_core.v`
- 微码生成: `wsg3/rom/gen_prom3m.py`
- 测试: `wsg3/tb/wsg3_func_tb.v`
