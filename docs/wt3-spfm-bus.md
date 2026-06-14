# WT3 SPFM 总线接口

## 概述

CPU 向声音芯片写入参数的异步总线接口，兼容 YM2413 双步写协议。

## 芯片清单 (3 IC)

| 芯片 | 封装 | 数量 | 功能 |
|------|------|------|------|
| 74HC373 | DIP-20 | 1 | D[7:0] 透明锁存 |
| 74HC174 | DIP-16 | 1 | 同步器 (addr_wr 3级+data_wr 2级) |
| 74HC377 | DIP-20 | 1 | 地址寄存器 |

CPU 侧信号 (CS_n, WR_n, A0, D[7:0], RST_n) 为外部输入，不占 IC 数量。
组合译码逻辑 (NOR/AND/INV) 为 PCB 飞线或离散器件，不占 IC 数量。

## 双步写协议

```
写地址: A0=0, CS_n=0, WR_n=0  (≥3 SPFM_CLK 周期)
间隙:   CS_n=1 或 WR_n=1      (≥1 SPFM_CLK 周期)
写数据: A0=1, CS_n=0, WR_n=0  (≥3 SPFM_CLK 周期)
间隙:   CS_n=1 或 WR_n=1
```

## 信号链

```
CPU 总线 (异步)
  ↓
U1: 373 透明锁存
  LE = ~(CS_n | WR_n)
  CS=0 & WR=0 时 Q 跟随 D，否则锁存
  ↓
组合译码 (PCB 飞线)
  write_active = ~CS_n & ~WR_n & RST_n
  addr_wr_comb = write_active & ~A0
  data_wr_comb = write_active & A0
  ↓
U2: 174 同步器 (posedge CLK)
  addr_wr 通道: R1→R2→R3, 上升沿检测 R2 & ~R3 → 1 clk 脉冲
  data_wr 通道: R1→R2, 上升沿检测 R2 & ~R1 → 1 clk 脉冲
  ↓
U3: 377 地址寄存器 (posedge CLK, Enable_bar=~addr_wr_pulse)
  addr_wr_pulse=1 期间锁存 d_latch → reg_addr
  ↓
输出:
  reg_addr       — 锁存的地址 (8-bit)
  reg_data       — 锁存的数据 (8-bit, 来自 373)
  addr_wr_pulse_n — 写地址脉冲 (1 clk 低, posedge CLK 对齐, 低有效)
  data_wr_pulse_n — 写数据脉冲 (1 clk 低, posedge CLK 对齐, 低有效)
```

## 时序约束

- 写脉冲宽度 ≥ 3 个 SPFM_CLK 周期 (2 拍同步延迟 + 1 拍边沿检测)
- 地址写与数据写之间间隙 ≥ 1 个 SPFM_CLK 周期
- 主机可异步驱动，不需要时钟对齐

## 文件清单

| 文件 | 说明 |
|------|------|
| rtl/wt3_spfm_bus.v | SPFM 总线接口模块 |
| rtl/hc377.v | 74HC377 模型 (377 地址寄存器实例) |
| tb/wt3_spfm_bus_tb.v | 独立验证 testbench |

## 验证结果

```
RAM[0x02] = 0xAA  ✓
RAM[0x05] = 0x55  ✓
RAM[0x0E] = 0xFF  ✓
PASS
```

编译/仿真命令:
```bash
iverilog -o tb/wt3_spfm_bus_tb.vvp rtl/wt3_spfm_bus.v rtl/hc377.v tb/wt3_spfm_bus_tb.v
vvp tb/wt3_spfm_bus_tb.vvp
```
