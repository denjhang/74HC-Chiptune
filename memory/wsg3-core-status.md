---
name: wsg3-core-status
description: wsg3_core.v 进度 - DAC 有输出但频率 ~2212Hz 不是 440Hz, 调试中
metadata:
  type: project
---

## 当前状态 (2026-06-15)

**DAC 有非零输出, 但频率约 2212Hz, 目标 A4=440Hz (快 5 倍)**

测试 `wsg3/tb/wsg3_func_tb.v`:
- SPFM 写入 A4=440Hz 频率 (0x012C6 nibble: 6 C 2 1 0), 音量 15, 波形 0 (sine)
- 50000 SPFM_CLK 采样, 47260 个非零 DAC 样本
- DFT 显示主峰在 ~2212Hz (期望 440Hz)

公式验证: `0x012C6 × 96000 / 2^20 = 4806 × 96000 / 1048576 = 440.00 Hz` (期望)
实测快 5 倍 → 相位累加器步进速度比期望快

## 已修复 bug (本轮)

1. **3M 微码 ROM 16-bit 解码** — 微码常量: 0xDEF7 (clear), 0xDEFF (write), 0xBFFF (output)
   控制 bit 映射: bit[3]=/CLR, bit[2]=/cp273 (输出步骤 active low), bit[1]=acc_we_n (写步骤 active low), bit[0]=clk174
   64 cells (16 step × 4 sub), LSB nibble = sub0. 生成器 `wsg3/rom/gen_prom3m.py`.

2. **X-propagation 根因 (U6 CS_n)** — `u6_cs_n = spfm_write_active ? reg_addr[4] : 1'b0`
   主机写 0x50-0x5F (freq/vol) 时 U6 (acc RAM) 被 deselect → TDM 读到 z → hc283 当 X → carry chain 永久 X 污染.
   **修复**: U6/U7 CS_n 始终为 0, 写使能单独按 reg_addr[4] 区分 (u6_we_n=0 当写 0x4x, u7_we_n=0 当写 0x5x).
   **Why**: TDM 引擎要持续读 U6, 不能用 CS_n 选择写目标.
   **How to apply**: 任何 LS189-style RAM 共享地址/数据 mux 时, 用 WE_n 而不是 CS_n 区分主机写目标.

3. **cd4066 inout 反馈 bug** — 模型同时 `assign IO1A = CTRL1 ? IO1B : 1'bz` 和 `assign IO1B = CTRL1 ? IO1A : 1'bz`
   双向驱动 IO1A=wave_nib[0] → CTRL=0 时 wave_nib 强制为 z → dac_out = wave×vol 全 X.
   **修复**: cd4066.v 只驱动 IO_B (从 IO_A 读), 不反向驱动 IO_A.
   **Why**: Verilog 仿真无法模拟真实双向开关的反向透传.
   **How to apply**: 所有模拟开关 (cd4066/cd4053) 仿真模型单向化, 硬件实际是双向的.

## 未解 bug: 频率快 5 倍

Trace: 5 个 nibble 加完后 `carry_chain=000011` (只 6-bit), 没扩展到 20-bit.

Pac-Man 文档 (reference/Namco WSG/Pac-Man 技术文档 第 209-211 行):
- `sum_1K = acc + freq + carry_chain[5]` (5-bit 加法, 进位输出)
- `sum_d_1L <= {sum_1K, sum_d_1L[3]}` (6-bit 滑窗: shift-in sum_1K, 保留 [3] 反馈)

**怀疑**: 算法应该是 acc[step] += freq[step] (4-bit nibble 累加, 进位通过 carry_chain 流转), 不是把整个 freq shift 进 carry chain. acc_we_n=0 步骤把 adder_s 写回 U6[step] (即新 acc 值), 下次该 voice 周期从更新后的 acc 开始.

需重读文档第 211 行附近的时序图, 确认每个 clk174 周期 U6 写入的是新 acc 还是 carry_chain 内容.

## 关键架构 (整体)

- 14 IC: 3 SPFM (373+174+377) + 11 WSG (86+39SF040+157+158+2×LS189+283+174+39SF040+273+4066)
- TDM 16 step (HCNT[5:2]), 每 step 4 sub-cycle (HCNT[1:0])
- ch0 用 5 nibble (step 0-4), ch1/ch2 用 4 nibble
- HCNT 6-bit, 主时钟 6.144MHz, TDM 96kHz
- spfm_write_active = `~CS_n & ~WR_n & RST_n` (外部协议译码, 不算隐藏门)
- hc157/hc158 Select=~spfm_write_active (写时选 CPU 侧, 扫描时选 TDM 侧)

## 文件位置

- 主模块: `wsg3/rtl/wsg3_core.v`
- 测试: `wsg3/tb/wsg3_func_tb.v`
- 3M 微码 hex: `wsg3/rom/wsg3_prom3m.hex` (64 cells 有效)
- 1M 波形 hex: `wsg3/rom/wsg3_prom1m.hex` (8 wave × 32 sample × 4-bit)
- 微码生成: `wsg3/rom/gen_prom3m.py`
- 波形生成: `wsg3/rom/gen_prom1m.py`

参见: [[wsg3-architecture]] 完整架构, [[rom-39sf040-only]] ROM 硬规则
