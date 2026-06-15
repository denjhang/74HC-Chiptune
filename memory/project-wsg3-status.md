---
name: project-wsg3-status
description: WSG3 Pac-Man 功能等效复刻当前进度 (283Hz 输出, 相位源问题中)
metadata:
  type: project
---

# WSG3 项目进度 (2026-06-16)

**目标**: 14 片 74HC (3 SPFM + 11 WSG) 功能等效复刻 1980 Pac-Man WSG。0 隐藏门, 只用 39SF040。

**测试向量**: 写 freq=0x012C6 → 0x50-0x54, vol=15 → 0x55, wave=0 → 0x45, 期望 A4=440Hz。

**当前状态**: DAC 输出 283Hz (目标 440Hz, 慢 0.64x)。

## 已修好的 bug

1. **3M 微码 ROM nibble 顺序** - 16-bit word 中 MSB nibble = sub0
   `gen_prom3m.py`: `nibble = (word >> (4 * (3 - sub))) & 0xF`

2. **cp273 未定义** - 添加 `wire cp273 = ~cp273_pulse_n & SPFM_RST_n & ~spfm_write_active;`

3. **X-propagation** - U6/U7 CS_n 始终为 0, WE_n 按 reg_addr[4] 区分

4. **cd4066 inout 反馈** - 单向驱动 IO_B

## 当前未解问题: 相位源

文档说 `rom1m_addr[4:0] = sum_d_1L[4:0]` (carry_chain[4:0]), 但这产生 283Hz。

carry_chain 是 6-bit 滑动窗, 每次 clk174 更新。5 个 nibble 加法过程中 carry_chain 会变化 5 次。

真正的 20-bit 累加器存在 U6[0..4] (5 nibble), 但 TDM 引擎每次只能读 1 个 nibble (由 tdm_step 选择)。

**关键问题**: 波形 ROM 地址采样时刻是哪个? 输出步骤 (step 5) 时应该能访问完整 20-bit 累加器?

## 项目结构

- `wsg3/rtl/wsg3_core.v` — 顶层
- `wsg3/rom/gen_prom3m.py` — 3M 微码生成
- `wsg3/tb/wsg3_func_tb.v` — 功能测试
