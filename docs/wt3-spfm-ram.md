# WT3 SPFM 总线 + 62256 参数 RAM

## 概述

SPFM 总线接口驱动 62256 静态 RAM，CPU 通过 YM2413 风格双步写协议写入参数。

## 芯片清单 (4 IC)

| 芯片 | 封装 | 数量 | 功能 |
|------|------|------|------|
| 74HC373 | DIP-20 | 1 | D[7:0] 透明锁存 |
| 74HC174 | DIP-16 | 1 | 同步器 |
| 74HC377 | DIP-20 | 1 | 地址寄存器 |
| CY62256 | DIP-28 | 1 | 参数 RAM (32K×8) |

## 62256 接线

```
A[7:0]  ← reg_addr (377 输出)
A[14:8] ← GND (只用低 256 字节)
DI[7:0] ← reg_data (373 输出)
WE_n    ← ~data_wr_pulse (SPFM 写数据脉冲, 低有效)
OE_n    ← RD_n (CPU 读时低有效)
CE_n    ← GND (始终选中)
DO[7:0] → ram_do (外部读取)
```

## 文件清单

| 文件 | 说明 |
|------|------|
| rtl/wt3_spfm_ram.v | SPFM+RAM 模块 |
| rtl/wt3_spfm_bus.v | SPFM 总线子模块 |
| rtl/hc377.v | 377 模型 |
| rtl/hc62256.v | 62256 模型 |
| tb/wt3_spfm_ram_tb.v | 验证 testbench |

## 验证结果

```
9/9 pass: 写入、读回、覆写、未写入地址全部正确
PASS
```

编译/仿真:
```bash
iverilog -o tb/wt3_spfm_ram_tb.vvp rtl/wt3_spfm_ram.v rtl/wt3_spfm_bus.v rtl/hc377.v rtl/hc62256.v tb/wt3_spfm_ram_tb.v
vvp tb/wt3_spfm_ram_tb.vvp
```
