# WT3 Core — 161 + 单片 ROM + 157 + 62256 + 377

## 概述

微码驱动的核心数据通路：161 step 计数器驱动单片 39SF040 微码 ROM，通过 157 mux 与 SPFM 共享单块 62256 RAM，377 锁存 RAM 输出。

## 芯片清单 (8 IC)

| 芯片 | 封装 | 数量 | 功能 |
|------|------|------|------|
| 74HC373 | DIP-20 | 1 | D[7:0] 透明锁存 (SPFM) |
| 74HC174 | DIP-16 | 1 | 同步器 (SPFM) |
| 74HC377 | DIP-20 | 2 | 地址寄存器 (SPFM) + 数据锁存 (RAM out) |
| 74HC161 | DIP-16 | 1 | 5-bit step 计数器 (级联) |
| 39SF040 | DIP-32 | 1 | 微码 ROM (8-bit 控制字) |
| 74HC157 | DIP-16 | 1 | RAM 地址 mux |
| CY62256 | DIP-28 | 1 | 参数 RAM (32K×8) |

## 微码 ROM 控制字 (8-bit)

```
bit 7:   ram_oe_n   (0=read RAM)
bit 6:   latch_n    (0=latch RAM output to 377, 低有效)
bit 5-0: ram_addr[5:0]
```

## 无隐藏门

所有连线为 PCB 飞线或直连，无外部反相器/逻辑门。

## 文件清单

| 文件 | 说明 |
|------|------|
| rtl/wt3_core.v | 核心模块 |
| rtl/wt3_spfm_bus.v | SPFM 总线子模块 |
| rtl/hc377.v, hc62256.v, hc157.v, hc161.v, hc39sf040.v | 芯片模型 |
| rom/wt3_microcode.hex | 微码 ROM |
| tb/wt3_core_tb.v | 验证 testbench |

## 验证结果

```
SPFM write 6 addresses → microcode read+latch → 6/6 PASS
```
