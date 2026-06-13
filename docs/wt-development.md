# Wavetable (WT) 合成器开发记录

## 项目概述

基于 Arduino Uno Wavetable Synthesis（作者 Keiji Katahira）移植的 WT 合成器核心，参考 STC32G 移植版 `wt.c` 的参数体系。

## WT 合成算法

### 核心公式

```
phase += step                          // 16-bit 相位累加
idx = phase[12:6]                      // 取 bit 12-6，7-bit 寻址 128 点 ROM
rom_addr = {wave_idx, level, vol, idx} // 19-bit ROM 地址
out = ROM[rom_addr]                    // 预计算 wave*(level+1)*(vol+1) >> 9
dac = sum(ch_out) clipped to ±128      // 混音裁剪
```

### 频率步进 (step) 计算

```
step = freq * 8192 / sample_rate
```

- `phase` 为 16-bit，`phase[12:6]` 取 bit 12 到 bit 6（7-bit），对应 128 点波形
- 8192 = 128 × 64，即 128 个波形点 × 每点 64 个 phase 单位
- step 最大支持 ~8191（约 8 kHz at 32051 Hz 采样率）

#### 常用音符 step 值（sample_rate = 32051Hz）

| 音符 | 频率 (Hz) | step 值 |
|------|-----------|---------|
| C4   | 261.6     | 67      |
| D4   | 293.7     | 75      |
| E4   | 329.6     | 84      |
| F4   | 349.2     | 89      |
| G4   | 392.0     | 100     |
| A4   | 440.0     | 112     |
| B4   | 493.9     | 126     |
| C5   | 523.3     | 134     |

STC32G 版采样率 17640Hz，对应 C4 step = `261.6 * 8192 / 17640 ≈ 121`。

### phase[12:6] vs phase[11:5]

STC32G 代码注释写 `pos >> 5`，但 step 公式用 8192（= 128 × 64）。如果用 `phase[11:5]`，每周期 = 128 × 32 = 4096 phase 单位，频率 = step × sr / 4096 = 2x 目标频率。用 `phase[12:6]` 每周期 = 128 × 64 = 8192，和 step 公式匹配。

### 波形 ROM (39SF040)

- **128 点**，有符号 8-bit（±31）
- 6 种波形：sqr, sq12, sq25, sine, saw, noise
- 波形数据来自 STC32G `wt.c` 的 `wt_waves[]`
- ROM 地址映射：`{wave_idx[2:0], level[3:0], vol[4:0], idx[6:0]}` = 19-bit
- 预计算 `wave × (level+1) × (vol+1) >> 9`，运行时零运算
- 占用 6 × 128 × 16 × 32 = 384KB，剩余 128KB

### ADSR 包络（简化）

4 状态：attack → sustain → release

- `level`: 0-15（4-bit，AY-3-8910 风格）
- `vol`: 0-31（5-bit，主机控制主音量）
- `env_rate`: 8-bit 计数器阈值
- attack: level 0→15，sustain: 保持，release: level 15→0

## SPFM 总线接口

### 信号定义

| 信号 | 方向 | 说明 |
|------|------|------|
| D[7:0] | 双向 | 数据总线 |
| A0 | 输入 | 0=写地址，1=写数据 |
| /CS | 输入 | 片选（低有效） |
| /WR | 输入 | 写选通（低有效） |
| /RD | 输入 | 读选通（低有效） |
| /RST | 输入 | 复位（低有效） |
| CLK | 输入 | 系统时钟 10 MHz |

### 寄存器映射

| 地址 | 名称 | 位宽 | 说明 |
|------|------|------|------|
| 0x00 | CTRL | [1:0] | 通道选择 |
| 0x01 | wave_idx | [2:0] | 波形选择 (0-5) |
| 0x02 | vol | [4:0] | 音量 (0-31) |
| 0x03 | env_rate | [7:0] | 包络速率 |
| 0x04 | step_lo | [7:0] | 频率步进低字节 |
| 0x05 | step_hi | [7:0] | 频率步进高字节 |
| 0x06 | note_on | - | 写触发（读回通道活跃状态） |
| 0x07 | note_off | - | 写触发 |

### 写时序

YM2413 风格，两步写：

1. **地址写**：A0=0, /CS=0, /WR=0, D=寄存器地址（保持 ≥3 个时钟）
2. **数据写**：A0=1, /CS=0, /WR=0, D=数据（保持 ≥3 个时钟）

参数配置顺序：先写波形属性（wave_idx, vol, env_rate, step），最后写 note_on 触发。

### 总线同步链

参考 YM2413 (IKAOPLL) 的 `rw_synchronizer`：

```
主机信号 → 异步锁存(d_latch) → 2级同步器 → 上升沿脉冲 → 写寄存器
```

- **异步锁存**：`/CS=0 & /WR=0` 时透明锁存 D 总线，不依赖时钟
- **2 级同步器**：地址/数据写请求各一路，消除亚稳态
- **上升沿脉冲**：同步后产生一个时钟宽的脉冲，防止重复写入
- **写脉冲宽度要求**：≥3 个时钟周期（2 拍同步延迟 + 1 拍余量）

主机可以异步驱动总线，不需要时钟对齐。任何 MCU（Z80, STC32G, Arduino）都能直接驱动。

## 仿真验证流程

### 完整编译/仿真/验证命令

```bash
# ---- 环境设置 ----
export PATH="/c/Users/denjhang/iverilog/bin:$PATH"

# ---- 4通道 ROM 查表 testbench（行为级） ----
iverilog -o tb/wt_rom_tb.vvp tb/wt_rom_tb.v
vvp tb/wt_rom_tb.vvp

# ---- SPFM 总线 testbench（例化 RTL） ----
iverilog -o tb/wt_spfm_tb.vvp rtl/wt_top.v tb/wt_spfm_tb.v
vvp tb/wt_spfm_tb.vvp

# ---- 转换 WAV ----
python3 csv_to_wav.py wt_output.csv
# 输出: wt_output.wav (8-bit signed, 32051Hz, mono)
```

### 验证结果（2026-06-12）

| 测试项 | 结果 |
|--------|------|
| C major chord (sine C4+E4+G4) | DFT: 262Hz, 329Hz, 392Hz |
| Multi-waveform (sqr+saw+noise+sine) | 4 通道独立混音 |
| Envelope attack | 0→15, 64 samples/level, smooth ramp |
| Envelope release | 15→0, smooth decay to silence |
| SPFM 总线同步链 | 异步驱动，≥3 周期写脉冲，正确响应 |

## iverilog 常见坑

### 1. `$sin()` 不支持

iverilog 不支持 `$sin()` 等数学函数。用 Python 生成 hex 文件，Verilog 中 `$readmemh` 加载。

### 2. 数组不能跨 always 块用 integer 索引

```verilog
// iverilog 报错: Could not find variable `phase[ch]'
reg [15:0] phase [0:3];
integer ch;
// 在一个 always 块中用 for + phase[ch]，另一个 always 块也用 → 报错
```

**解决**：展开为独立寄存器（phase0, phase1, phase2, phase3），用 `case(cur_ch)` 代替数组索引。

### 3. 非阻塞赋值导致同一周期数据不传播

```verilog
// 错误：ROM 读到旧 phase
phase0 <= phase0 + step_val0;
ch_out0 <= rom_data[{..., phase0[12:6]}];

// 正确：阻塞赋值，同周期内传播
phase0 = phase0 + step_val0;
ch_out0 = rom_data[{..., phase0[12:6]}];
```

行为级仿真中用阻塞赋值（`=`）做合成核心，保证 phase 累加后立刻用新值查表。

### 4. testbench 信号驱动时序竞争

```verilog
// 错误：posedge clk 后赋值和 RTL posedge 采样竞争
@(posedge clk);
d_out = data;  // 和 RTL 的 posedge 检测同时发生

// 正确：用 negedge 驱动，或加延迟
@(negedge clk);
d_out = data;
```

有同步链后，这个问题已被吸收 — 主机信号不需要和时钟对齐。

## RAM 架构 (wt_ram.v) — 9 IC 方案

### 架构概述

用 62256 SRAM 替代全部通道寄存器，74161 微程序步进器驱动分时复用。单套算术寄存器（acc_lo, acc_hi, carry）共享于 4 通道。

### 芯片清单

| 芯片 | 数量 | 功能 |
|------|------|------|
| 74161 | 1 | 微程序步进计数器 (3-bit) |
| 74283 | 2 | 16-bit 相位累加器 (8-bit × 2, carry-chain) |
| 74377 | 2 | 地址锁存 + 数据锁存 |
| 74157 | 1 | 地址二选一 mux (RAM/ROM 切换) |
| 74138 + 7404 | 2 | 控制信号解码 |
| 39SF040 | 1 | 512KB Flash — 全部查找表 |
| 62256 | 1 | 32KB SRAM — 全部通道寄存器 |

**总计: 9 IC**

### RAM 寄存器映射 (62256)

每通道 16 字节, 4通道 = 64 字节 (62256 有 32KB, 空间绰绰有余)

| 地址 | 字段 | 位宽 | 说明 |
|------|------|------|------|
| ch×16+0 | phase_lo | 8 | 相位低字节 |
| ch×16+1 | phase_hi | 8 | 相位高字节 |
| ch×16+2 | step_lo | 8 | 频率步进低字节 |
| ch×16+3 | step_hi | 8 | 频率步进高字节 |
| ch×16+4 | level | 4 | 包络电平 0-15 |
| ch×16+5 | env_state | 3 | 包络状态 (0=off, 1=atk, 2=sus, 3=rel) |
| ch×16+6 | env_cnt | 8 | 包络计数器 |
| ch×16+7 | vol | 5 | 音量 0-31 |
| ch×16+8 | dac_out | 8 | DAC 输出 (调试) |
| ch×16+9 | wave_idx | 3 | 波形选择 0-5 |
| ch×16+10 | env_rate | 8 | 包络速率 |

### 微程序时序

```
10 MHz 时钟, 32051 Hz 采样率
每采样周期 = 312 个时钟

微程序: 4通道 × 32步 = 128 步 (每步 1 时钟)
空闲:   312 - 128 = 184 个时钟 (SPFM 总线操作)
```

### 每通道微步 (20 步, 步 20-31 为 NOP)

| 步 | 操作 | RAM/ROM | 说明 |
|----|------|---------|------|
| 0 | 读 phase_lo | RAM | 设地址+OE |
| 1 | 锁存 phase_lo, 读 step_lo | RAM | 非阻塞锁存 + 下一地址 |
| 2 | acc_lo += step_lo, 写回 phase_lo | RAM | 74283 加法 + RAM 写 |
| 3 | 读 phase_hi | RAM | 设地址+OE |
| 4 | 锁存 phase_hi, 读 step_hi | RAM | 非阻塞锁存 |
| 5 | acc_hi += step_hi + carry, 写回 | RAM | 16-bit 累加完成 |
| 6 | 读 level | RAM | |
| 7 | 锁存 level, 读 vol | RAM | |
| 8 | 锁存 vol, 读 wave_idx | RAM | |
| 9 | 锁存 wave_idx, 读 env_state | RAM | |
| 10 | 锁存 env_state, 设 ROM 地址 | ROM | phase[12:6] 拼接 |
| 11 | 锁存 ROM 输出, 累加到 mix_sum | ROM | 有符号累加 |
| 12 | 读 env_cnt | RAM | |
| 13 | 锁存 env_cnt, 读 env_rate | RAM | |
| 14 | 锁存 env_rate, 包络计算 | — | level ±1, env_cnt ±1 |
| 15 | 写 env_state | RAM | |
| 16 | 写 level | RAM | |
| 17 | 写 env_cnt | RAM | |
| 18 | 写 dac_out | RAM | 调试用 |
| 19 | NOP | — | |

### RAM 时序模型

62256 SRAM 是**异步读**（地址+OE 有效后数据立即输出，不依赖时钟）。仿真中用组合逻辑建模：

```verilog
// RAM 读: 组合逻辑 (异步)
always @(*) begin
    if (!ram_oe_n && !ram_cs_n)
        ram_out = sram[ram_addr];
end

// RAM 写: negedge clk 采样 (DUT 非阻塞赋值已传播)
always @(negedge clk) begin
    if (!ram_we_n && !ram_cs_n)
        sram[ram_addr] = ram_io;
end
```

DUT 的 ram_addr/ram_oe_n/ram_we_n 是寄存器输出 (posedge clk 非阻塞更新)。
写操作在 negedge clk 采样，此时 DUT 的新值已传播。

### SPFM note_on 时序

SPFM note_on 需要 10 次 RAM 写入（phase_lo=0, phase_hi=0, step_lo, step_hi, level=0, env_state=1, env_cnt=0, vol, wave_idx, env_rate）。在微程序空闲期（ustep >= 128）逐拍写入。主机需要在 note_on 之间等待至少 1 个采样周期（312 时钟）。

### 通道映射 bug

初始版本用 `uch = ustep[6:5]` 做 4 通道映射，但 STEPS_PER_CH=20 不是 2 的幂，导致通道 2/3 的微步偏移错误。修复: STEPS_PER_CH 改为 32（2 的幂），`uch = ustep[6:5]` 和 `ums = ustep[4:0]` 正确对齐。

### 验证结果（2026-06-12）

| 测试项 | wt_top.v (寄存器) | wt_ram.v (RAM) |
|--------|-------------------|----------------|
| C4 (262Hz) | 61344 | 61475 |
| E4 (329Hz) | 60566 | 60764 |
| G4 (392Hz) | 61238 | 61353 |
| C major chord | DFT 三频确认 | DFT 三频确认 |
| 多音色 (sqr+saw+noise+sine) | 4通道独立 | 4通道独立 |
| Envelope attack/release | 正确 | 正确 |
| 输出范围 | ±109 | ±109 |

## RTL 门级映射 (wt_rtl.v)

### 概述

wt_rtl.v 是 wt_ram.v 的 74HC 门级映射版本，微程序逻辑与 wt_ram.v 完全一致，输出 bit-perfect match（5000 样本 0 差异）。

### 74HC 芯片映射

| 编号 | 芯片 | 宽度 | 功能 | 仿真实现 |
|------|------|------|------|----------|
| U2 | 74283 | 8-bit | phase_lo 加法器 (acc_lo + step_lo) | Verilog `+` (验证用) |
| U3 | 74283 | 8-bit | phase_hi 加法器 (acc_hi + step_hi + carry) | Verilog `+` (验证用) |
| U4 | 74377 | 15-bit | RAM 地址锁存 (posedge clk) | `reg ram_addr_r <=` |
| U5f | 74377 | 19-bit | ROM 地址锁存 (step 10 使能) | `reg rom_addr_r <=` |
| U5g | 74377 | 8-bit | DAC 输出锁存 (step 127 使能) | `reg dac_out_r <=` |
| U5h | 74377 | 8-bit | RAM 写数据锁存 | `reg ram_wdata <=` |
| U7 | 74138 | 3-to-8 | 微步组译码器 (ums[4:2]) | 验证用 (不影响时序) |

### 74377 锁存使能映射

74377 在硬件中用 Enable_bar (低有效) 控制，微程序各步对应的使能信号：

| 微步 | 操作 | U4 (RAM addr) | U5f (ROM addr) | U5g (DAC) | U5h (RAM wdata) |
|------|------|:---:|:---:|:---:|:---:|
| 0 | 读 phase_lo | 1 | | | |
| 1 | 锁存 phase_lo, 读 step_lo | 1 | | | |
| 2 | 加法, 写 phase_lo | 1 | | | 1 |
| 3 | 读 phase_hi | 1 | | | |
| 4 | 锁存 phase_hi, 读 step_hi | 1 | | | |
| 5 | 加法, 写 phase_hi | 1 | | | 1 |
| 6 | 读 level | 1 | | | |
| 7 | 锁存 level, 读 vol | 1 | | | |
| 8 | 锁存 vol, 读 wave_idx | 1 | | | |
| 9 | 锁存 wave_idx, 读 env_state | 1 | | | |
| 10 | 锁存 env_state, 设 ROM 地址 | | 1* | | |
| 11 | 锁存 ROM 输出 | | | | |
| 12 | 读 env_cnt | 1 | | | |
| 13 | 锁存 env_cnt, 读 env_rate | 1 | | | |
| 14 | 锁存 env_rate, 包络计算 | | | | |
| 15 | 写 env_state | 1 | | | 1 |
| 16 | 写 level | 1 | | | 1 |
| 17 | 写 env_cnt | 1 | | | 1 |
| 18 | 写 dac_out (调试) | 1 | | | 1 |
| 127 | DAC 输出锁存 | | | 1 | |

\* ROM 地址仅在 env_state != 0 时锁存

### 工作寄存器 (74377 + 74157 mux)

硬件中每个工作寄存器用 74377 锁存，D 端通过 74157 mux 选择数据源：

| 寄存器 | 位宽 | D 端 mux 选择 | 74157 Sel |
|--------|------|---------------|-----------|
| acc_lo | 8 | ram_io (step 1) / alu_lo_sum (step 2) | ums[4:0] |
| acc_hi | 8 | ram_io (step 4) / alu_hi_sum (step 5) | ums[4:0] |
| step_lo_r | 8 | ram_io (step 1, 锁存 phase_lo 同时) | 固定 |
| step_hi_r | 8 | ram_io (step 4, 锁存 phase_hi 同时) | 固定 |
| level_r | 4 | ram_io (step 7) | 固定 |
| vol_r | 5 | ram_io (step 8) | 固定 |
| wave_idx_r | 3 | ram_io (step 9) | 固定 |
| env_state_r | 3 | ram_io (step 10) | 固定 |
| env_cnt_r | 8 | ram_io (step 13) | 固定 |
| env_rate_r | 8 | ram_io (step 14) | 固定 |

### 74138 微步组译码器

74138 译码 ums[4:2]（3-bit）→ 8 组控制线：

| ums[4:2] | 微步范围 | 功能组 |
|----------|---------|--------|
| 0 | 0-7 | phase 累加 (读/加/写) |
| 1 | 8-15 | 参数读取 + ROM 查表 |
| 2 | 16-23 | 包络写回 + DAC |
| 3 | 24-31 | NOP |
| 4-7 | — | 未使用 |

硬件中 74138 的 8 个输出经 7404 反相后，配合 ums[1:0] 的门电路产生具体的 ram_oe/ram_we/ram_cs/latch_en 控制信号。

### 仿真验证注意事项

1. **74377 不能直接实例化用于仿真**: 74377 的 `always @(posedge Clk)` 和主控制块的 `always @(posedge clk)` 在 iverilog 中存在仿真竞争。RAM 地址等需要在**当前时钟周期**立即可用的信号，不能通过 74377 实例传递（1 拍延迟风险）。
2. **74283 组合逻辑拖慢仿真**: 8-bit 宽度的 `always @(*)` 在 iverilog 中产生大量敏感列表传播。编译时不包含 74HC 库文件，改用 Verilog `+` 运算符。
3. **等效性**: `reg x <= value` 在 posedge clk 非阻塞赋值，与 74377 的 `Q_current <= D` 行为完全等效。

### 验证结果（2026-06-12）

| 测试项 | wt_ram.v | wt_rtl.v |
|--------|----------|----------|
| C major chord (sine C4+E4+G4) | DFT: 262, 329, 392 Hz | DFT: 262, 329, 392 Hz |
| 5000 样本逐样本对比 | 基准 | **0 差异 (bit-perfect)** |

## 硬件时序分析 (39SF040 + 62256)

### SRAM (CY62256N) 读时序

**RTL 模式**: Step N posedge clk 设置 `ram_addr_r` (74377 锁存)，Step N+1 posedge clk 读取 `ram_io`。

**关键路径**: 74377 tpd (~25ns) + SRAM tAA (55/70ns) + 目标寄存器 setup (~5ns) = **85ns (commercial) / 100ns (industrial)**

| 参数 | 商业级 (0-70°C) | 工业级 (-40~85°C) | 时钟周期 |
|------|:---:|:---:|:---:|
| SRAM tAA | 55ns | 70ns | 100ns |
| 74377 tpd | ~25ns | ~25ns | — |
| 目标 setup | ~5ns | ~5ns | — |
| **总需求** | **~85ns** | **~100ns** | 100ns |
| **裕量** | **~15ns** | **~0ns** | — |

**结论**: 商业级 OK（15ns 裕量）；工业级零裕量，**不可靠**。

### SRAM (CY62256N) 写时序

**RTL 模式**: 写步骤同时设置 addr/data/WE#，下一 posedge clk 恢复默认。WE# 脉宽 = 1 clock = 100ns。

| 参数 | 最小值 | 实际值 | 裕量 |
|------|:---:|:---:|:---:|
| tPWE (WE# 脉宽) | 40/50ns | 100ns | 2× |
| tAW (addr setup to WE# ↑) | 45/60ns | 100ns | ~2× |
| tSD (data setup to WE# ↑) | 25/30ns | ~60ns | 2× |
| tHA (addr hold after WE# ↑) | 0ns | ~0ns | OK |

**结论**: 写时序充裕，无问题。

### ROM (SST39SF040) 读时序

**RTL 模式**: Step 10 posedge clk 设置 `rom_addr_r` (74377)，Step 11 posedge clk 读取 `rom_data`。与 SRAM 读路径相同。

| 参数 | 商业级 | 工业级 | 裕量 |
|------|:---:|:---:|:---:|
| ROM tAA | 55ns | 70ns | — |
| 74377 tpd | ~25ns | ~25ns | — |
| 目标 setup | ~5ns | ~5ns | — |
| **总需求** | **~85ns** | **~100ns** | — |
| **裕量** | **~15ns** | **~0ns** | — |

**建议**: OE# 硬接线到 GND（常低），消除 tOEA 延迟。

### 总线负载分析

| 总线 | 负载电容 | 74HC 驱动能力 | 结论 |
|------|:---:|:---:|:---:|
| RAM 数据 (ram_io) | SRAM 6pF + 74377 10pF + 74157 10pF ≈ 26pF | IOH -4mA @ 50pF | OK |
| RAM 地址 (A0-A14) | SRAM 6pF + 74377 10pF ≈ 16pF/引脚 | IOH -4mA | OK |
| ROM 地址 (A0-A18) | Flash 12pF + 74377 10pF ≈ 22pF/引脚 | IOH -4mA | OK |
| ROM 数据 (DQ0-DQ7) | Flash 12pF + 寄存器输入 ≈ 14pF | IOH -4mA | OK |

### 安全工作频率

| 配置 | 时钟频率 | 读裕量 | 可靠性 |
|------|:---:|:---:|:---:|
| 商业级 (55ns) | 10 MHz | ~15ns | OK |
| 商业级 (55ns) | 12 MHz | ~-5ns | 不可行 |
| 工业级 (70ns) | 10 MHz | ~0ns | **不可靠** |
| 工业级 (70ns) | 8 MHz | ~25ns | OK |
| 工业级 (70ns) | 6 MHz | ~42ns | 充裕 |

**推荐**: 10MHz + 商业级芯片，或 8MHz + 工业级芯片。

### 硬件设计建议

1. **ROM OE# 接 GND** — 消除 tOEA，节省 ~5ns
2. **ROM WE# 接 VDD (10kΩ 上拉)** — 防止意外写入
3. **上电延迟 100µs** — SST39SF040 要求 VDD 稳定 100µs 后再访问
4. **SRAM OE# 由译码器控制** — 微程序空闲期 OE# 拉高，降低功耗
5. **去耦电容** — 每片 IC VDD 旁 100nF 陶瓷电容，39SF040 加 10µF 钽电容

## 文件清单

| 文件 | 说明 |
|------|------|
| `rtl/wt_top.v` | WT 合成器 RTL，SPFM 总线接口，4 通道展开寄存器（原始版） |
| `rtl/wt_ram.v` | WT 合成器 RTL，62256 RAM + 74161 微程序步进器，9 IC 方案 |
| `rtl/wt_rtl.v` | WT 合成器 RTL，74HC 门级映射版本（74377/74283/74138 标注） |
| `tb/wt_fast_tb.v` | 快速行为级 testbench（单通道验证） |
| `tb/wt_rom_tb.v` | 4 通道查表 testbench（行为级，直接寄存器访问） |
| `tb/wt_spfm_tb.v` | SPFM 总线 testbench（例化 wt_top，YM2413 风格时序） |
| `tb/wt_ram_tb.v` | RAM 架构 testbench（例化 wt_ram，异步 RAM 模型） |
| `tb/wt_rtl_tb.v` | RTL 门级 testbench（例化 wt_rtl，快速 5000 样本对比） |
| `rom/wt_39sf040.hex` | 512KB ROM hex（6 波形 × 128 点 × 16 level × 32 vol） |
| `rom/wt_39sf040.bin` | 512KB ROM 二进制（烧录用） |
| `csv_to_wav.py` | CSV → WAV 转换（32051Hz, 8-bit signed） |
| `reference/sst39sf040.docx` | SST39SF040 512KB Flash ROM datasheet |
| `reference/infineon-cy62256n-256-kbit-32-k-8-static-ram-datasheet-en.docx` | CY62256N 32KB SRAM datasheet |

## 参考项目

- STC32G 移植版: `D:\working\vscode-projects\STC_Chiptune\STC32G12K128\wt.c`
  - 16 通道，128 点波形表，14 种波形，ADSR 包络
  - **这是频率参数和算法的权威参考**
- Arduino 原版: Keiji Katahira 的 ArduinoUno_wavetable_synthesis
- IKAOPLL (YM2413): `reference/IKAOPLL-main/`
  - **总线同步链参考** — 异步锁存 + 2 级同步器 + 上升沿脉冲
- Gigatron TTL: http://gigatron.io/ — 查表 MCU 架构灵感
