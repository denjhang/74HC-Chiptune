# WT3 Core — 161 + 单片 ROM + 157×5 + 62256 + 377×3 + 283

## 概述

微码驱动的核心数据通路：161 step 计数器驱动单片 39SF040 微码 ROM，通过 5 片 157 mux 与 SPFM 共享单块 62256 RAM，2 片 377 锁存 RAM 输出，283 完成相位累加。

## 芯片清单 (14 IC)

| 芯片 | 封装 | 数量 | 功能 |
|------|------|------|------|
| 74HC373 | DIP-20 | 1 | D[7:0] 透明锁存 (SPFM) |
| 74HC174 | DIP-16 | 1 | 同步器 (SPFM) |
| 74HC377 | DIP-20 | 3 | SPFM 地址 + reg_a + reg_b |
| 74HC161 | DIP-16 | 1 | 5-bit step 计数器 (级联) |
| 39SF040 | DIP-32 | 1 | 微码 ROM (8-bit 控制字) |
| 74HC157 | DIP-16 | 5 | RAM 地址低/高 4 位 + DI 低/高 4 位 + WE/OE |
| CY62256 | DIP-28 | 1 | 参数 RAM (32K×8) |
| 74HC283 | DIP-16 | 1 | 4-bit 全加器 |

## 微码 ROM 控制字 (8-bit)

```
bit 7: ram_oe_n   (0=read RAM)
bit 6: latch_a_n  (0=latch to reg_a, 低有效)
bit 5: latch_b_n  (0=latch to reg_b, 低有效)
bit 4: mc_we_n    (0=write adder result back to RAM)
bit 3-0: ram_addr[3:0]
```

## 数据通路 (单通道 4-bit 相位累加)

| step | hex | 动作 |
|------|-----|------|
| 0 | 0x70 | OE=0, addr=0x00 (读 RAM[0]=phase_acc, RAM 输出稳定) |
| 1 | 0x30 | latch_a_n=0, addr=0x00 (377_a 锁存 RAM[0]) |
| 2 | 0x71 | OE=0, addr=0x01 (读 RAM[1]=phase_step) |
| 3 | 0x51 | latch_b_n=0, addr=0x01 (377_b 锁存 RAM[1]) |
| 4 | 0xE0 | mc_we_n=0, addr=0x00 (写回 283 结果到 RAM[0]) |
| 5-31 | 0xF0 | NOP |

32 步循环 = 1 次累加, 96kHz

## 157 mux 分配

| IC | 用途 | Select | A (CS_n=0, SPFM) | B (CS_n=1, 微码) |
|----|------|--------|------------------|-------------------|
| #1 | RAM 地址低 4 位 | SPFM_CS_n | reg_addr[3:0] | mc_ram_addr[3:0] |
| #2 | RAM 地址高 4 位 | SPFM_CS_n | reg_addr[7:4] | 0 |
| #3 | RAM DI 低 4 位 | SPFM_CS_n | reg_data[3:0] | adder_s[3:0] |
| #4 | RAM DI 高 4 位 | SPFM_CS_n | reg_data[7:4] | 0 |
| #5 | RAM WE_n + OE_n | SPFM_CS_n | data_wr_pulse_n / 1 | mc_we_n / ram_oe_n_mc |

## 无隐藏门

所有连线为 PCB 飞线或直连，无外部反相器/逻辑门。所有 2:1 选择点全部由 5 片 157 显式实现。

## 文件清单

| 文件 | 说明 |
|------|------|
| rtl/wt3_core.v | 核心模块 (14 IC) |
| rtl/wt3_spfm_bus.v | SPFM 总线子模块 (373 + 174 + 377) |
| rtl/hc377.v, hc62256.v, hc157.v, hc161.v, hc39sf040.v, hc283.v | 芯片模型 |
| rom/wt3_microcode.hex | 微码 ROM (32 字节) |
| tb/wt3_core_tb.v | 验证 testbench |

## 验证结果

```
SPFM write phase_acc=0x03, phase_step=0x02
After 1 cycle:
  reg_a_q = 0x03 (锁存 RAM[0])
  reg_b_q = 0x02 (锁存 RAM[1])
  adder_s = 0x5  (3+2)
After 2 cycle:
  reg_a_q = 0x05 (RAM[0] 已被写回 0x5)
4/4 PASS
```
