# WT3 SPFM 总线 + 157 Mux + 62256 RAM

## 概述

SPFM 总线接口通过 157 地址 mux 与 62256 RAM 连接，实现 CPU 写入和微码读取的时分复用。

## 芯片清单 (5 IC)

| 芯片 | 封装 | 数量 | 功能 |
|------|------|------|------|
| 74HC373 | DIP-20 | 1 | D[7:0] 透明锁存 |
| 74HC174 | DIP-16 | 1 | 同步器 |
| 74HC377 | DIP-20 | 1 | 地址寄存器 |
| 74HC157 | DIP-16 | 1 | RAM 地址 mux (低 4 位) |
| CY62256 | DIP-28 | 1 | 参数 RAM (32K×8) |

## 地址 Mux (157)

```
Select = CS_n (157 真值: Select=0→Y=A, Select=1→Y=B)
  CS_n=0 (SPFM 写): Select=0 → Y=A → A 接 reg_addr
  CS_n=1 (微码读):   Select=1 → Y=B → B 接 mc_ram_addr

高 4 位: CS_n ? mc_ram_addr[7:4] : reg_addr[7:4] (wire 连线)
```

## 62256 接线

```
A[7:0]  ← 157 mux 输出
A[14:8] ← GND
DI[7:0] ← reg_data (373 输出, 直连)
WE_n    ← data_wr_pulse_n (直连, 无隐藏反相)
OE_n    ← CS_n ? mc_oe_n : 1'b1 (SPFM 时不读)
CE_n    ← GND
```

## 无隐藏门

- 377 Enable_bar 直连 addr_wr_pulse_n
- 62256 WE_n 直连 data_wr_pulse_n
- 157 A/B 接线互换 (A=reg_addr, B=mc_ram_addr) 避免 CS_n 反相

## 仿真建模

- hc377, hc174 加 #1ns propagation delay (真实硬件 ~15ns)
- hc62256 改为 negedge WE_n 触发写入 (更接近真实硬件行为)

## 文件清单

| 文件 | 说明 |
|------|------|
| rtl/wt3_spfm_mux.v | SPFM+MUX+RAM 模块 |
| rtl/wt3_spfm_bus.v | SPFM 总线子模块 |
| rtl/hc377.v | 377 模型 |
| rtl/hc62256.v | 62256 模型 |
| rtl/hc157.v | 157 模型 |
| tb/wt3_spfm_mux_tb.v | 验证 testbench |

## 验证结果

```
3 个 testbench 全部 PASS:
  SPFM Bus:  PASS
  SPFM RAM:  9/9 pass
  SPFM Mux:  9/9 pass
```
