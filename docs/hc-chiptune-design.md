# 74HC-Chiptune 设计文档

基于 Pac-Man WSG 架构，使用 74HC TTL 芯片构建 3 通道波形合成器。

## 架构概览

```
SPFM 总线 → 373/174/377 (3 IC) → 7134 参数 RAM → 合成器数据通路
                                                        ↓
3.072MHz / 32 = 96kHz                                  hc161×2 → 指令 ROM (39SF040)
32 步循环: v0(8步) + v1(8步) + v2(8步) + NOP(8步)       ↓
每通道: 5累加 + vol读 + wave读 + ROM查表 = 8步
混音: 软件加法, 3通道 8-bit 值累加到 273 输出
```

## 时钟

- 晶振: **3.072 MHz** (直接驱动 STEP_CLK)
- STEP_CLK → hc161×2 CP → 32 步循环 (5-bit step counter)
- 96kHz = 3.072MHz / 32 (step 跑一轮 = 一个采样周期)

## 芯片清单 (10 IC)

| 部分 | 芯片 | 数量 | 说明 |
|------|------|------|------|
| **SPFM 总线接口** | 74HC373 | 1 | D[7:0] 透明锁存 |
| | 74HC174 | 1 | 两路同步器 |
| | 74HC377 | 1 | 地址寄存器 |
| **合成器核心** | 74HC161 | 2 | 微步计数器 step[4:0] (级联) |
| | 74HC283 | 1 | 4-bit 全加器 (相位累加) |
| | 74HC174 | 1 | 累加器锁存 + vol/wave 锁存 |
| | 74HC273 | 1 | 混音输出锁存 (dac_out) |
| | 39SF040 | 3 | 指令 ROM (2片) + 波表 ROM |
| | 7134 | 1 | 双端口参数 RAM |
| | 62256 | 1 | phase 存储 |
| **总计** | | **10** | |

## 32 步循环

```
step  0: v0 清零加法器 + nibble 0 累加
step  1: v0 nibble 1 累加
step  2: v0 nibble 2 累加
step  3: v0 nibble 3 累加
step  4: v0 nibble 4 累加
step  5: v0 读 vol (7134 addr voice×8+6)
step  6: v0 读 wave (7134 addr voice×8+5)
step  7: v0 ROM 查表 → 混音锁存

step  8-15: v1 同上
step 16-23: v2 同上 (查表后同时锁存 dac_out)
step 24-31: NOP (0x6FFF)
```

## 指令 ROM 控制字格式 (16-bit)

每步 16-bit, 存在 39SF040 指令 ROM (2片拼 16-bit), 地址 = step × 2

| Bit | 名称 | 说明 |
|-----|------|------|
| 15 | adder_clk | 1=上升沿锁存 283 加法结果 |
| 13 | adder_clr_n | 0=清零加法器 (每通道第一步) |
| 12 | out_latch | 1=查表步, 锁存 ROM 输出到 mix |
| 11 | param_oe_n | 0=读 7134 参数 |
| 10 | ram_oe_n | 0=读 62256 phase |
| 9 | rom_oe_n | 0=读波表 ROM |
| 7:4 | param_addr | 7134 子地址: 0-4=freq, 5=wave, 6=vol |
| 3:0 | voice_sel | 当前通道 (0/1/2) |

## 波表 ROM (128 点)

地址 = {wave[2:0], vol[3:0], phase[19:12]} (15-bit, 零扩展到 19-bit)

- 8 种波形 × 16 音量 × 256 索引 = 32768 字节 (32KB)
- 波形 128 点, 4-bit 无符号 (0-15), 预计算 wave[sample] × vol = 8-bit (0-225)
- phase[19:12] 为 8-bit, 超过 128 的索引自动循环 (idx % 128)
- 存在第三片 39SF040

### 波形列表

| 索引 | 名称 | 说明 |
|------|------|------|
| 0 | sine | 正弦波 |
| 1 | square | 方波 (50%) |
| 2 | sq12 | 窄方波 (12.5%) |
| 3 | sq25 | 窄方波 (25%) |
| 4 | saw | 锯齿波 |
| 5 | triangle | 三角波 |
| 6 | noise | 伪随机噪声 |
| 7 | sine2x | 二倍频正弦 |

## 参数 RAM (7134) 地址映射

| 地址 | 字段 | 说明 |
|------|------|------|
| voice×8 + 0..4 | freq nibble 0..4 | 频率步进 (每 nibble 4-bit, 低地址低位) |
| voice×8 + 5 | wave_idx | 波形选择 (低 3 bit) |
| voice×8 + 6 | vol | 音量 (低 4 bit, 0=静音, 15=最大) |

Right 端口地址 = {7'b0, voice[3:0], 3'b0} + {8'b0, param_addr[3:0]}

## Phase RAM (62256) 地址映射

| 地址 | 字段 | 说明 |
|------|------|------|
| voice×5 + 0..4 | phase nibble 0..4 | 累加器相位 (硬件读写, CPU 不访问) |

## 频率计算

`step = freq × 2^20 / 96000`

| 音符 | 频率 | step (20-bit) |
|------|------|---------------|
| C4 | 261.63 | 0x0B2A |
| D4 | 293.66 | 0x0C88 |
| E4 | 329.63 | 0x0E14 |
| F4 | 349.23 | 0x0EE7 |
| G4 | 392.00 | 0x10BA |
| A4 | 440.00 | 0x12C6 |
| B4 | 493.88 | 0x1513 |
| C5 | 523.25 | 0x1653 |

## 音域

- 最低音 (step=1): 96000 / 2^20 = **0.091 Hz**
- 最高音 (step=0xFFFFF): **2963 Hz**

## 混音与输出

查表步依次将 3 通道的 8-bit ROM 值累加:

- step 7 (v0 lookup): mix = rom_dq
- step 15 (v1 lookup): mix = mix + rom_dq
- step 23 (v2 lookup): mix = mix + rom_dq, 同时锁存 dac_out = mix

3 路最大 225+225+225=675, 8-bit 截断。dac_out 为无符号 8-bit。

## 仿真说明

仿真中以下模块用 reg 实现 (避免跨实例 NBA 时序竞争):

| reg | 对应硬件 | 说明 |
|-----|---------|------|
| accum_q[5:0] | 74HC174 | 累加器锁存 (含进位) |
| phase_mem[0:19] | 74HC62256 | 20 个 4-bit phase nibble |
| phase_v0/v1/v2 | 62256 内容 | 3×20-bit phase 寄存器 |
| mix_out[7:0] | 74HC273 | 混音累加器 |
| cur_vol_r, cur_wave_r | 74HC174 | vol/wave 锁存 |
| dac_out_r[7:0] | 74HC273 | DAC 输出锁存 |

真实硬件上这些可以直接实例化, 无时序问题。

## 芯片模型文件

| 文件 | 芯片 | 来源 |
|------|------|------|
| rtl/hc7134.v | IDT7134 双端口 SRAM | 自建 |
| rtl/hc62256.v | CY62256N SRAM | 自建 |
| rtl/hc39sf040.v | SST39SF040A Flash ROM | 自建 |
| rtl/hc283.v | 74HC283 4-bit 全加器 | 自建 |
| rtl/hc174.v | 74HC174 六D触发器 | 自建 |
| rtl/hc161.v | 74HC161 4-bit 计数器 | 自建 |
| rtl/hc273.v | 74HC273 八D触发器 | ice-chips 库 |

## ROM 文件

| 文件 | 用途 | 大小 |
|------|------|------|
| rom/rom_instruction.hex | 指令 ROM (gen_rom.py 生成) | 512KB |
| rom/rom_wavetable.hex | 波表 ROM (gen_rom.py 生成, 32KB 有效) | 512KB |
| rom/gen_rom.py | ROM 生成脚本 | - |

## 参考

- Pac-Man 技术文档: `reference/Namco WSG/Pac-Man技术文档_extracted/`
- Pac-Man Emulation Guide: `reference/Namco WSG/PacmanEmulation_extracted/`
- STC32G WT 合成: `D:\working\vscode-projects\STC_Chiptune\STC32G12K128\wt.c`
