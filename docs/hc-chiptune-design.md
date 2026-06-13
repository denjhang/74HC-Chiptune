# 74HC-Chiptune 从零设计记录

从零设计，使用 74HC 芯片构建 WT 合成器。参考 YM2413 (IKAOPLL) 总线时序，但不复制任何具体实现。

## 项目概述

4 通道 WT 合成器，SPFM 总线接口，74HC TTL 芯片实现。

### 目标芯片清单

| 部分 | 芯片 | 数量 | 状态 |
|------|------|------|------|
| **SPFM 总线接口** | | **3** | **完成** |
| | 74HC373 | 1 | D[7:0] 透明锁存 |
| | 74HC174 | 1 | 两路同步器 (2×3 D-FF) |
| | 74HC377 | 1 | 地址寄存器 (8-bit) |
| **合成器核心** | | **9** | 设计中 |
| | 74HC161 | 1 | 微程序步进计数器 |
| | 74HC283 | 2 | 16-bit 相位累加器 |
| | 74HC377 | 2 | 地址锁存 + 数据锁存 |
| | 74HC157 | 1 | 地址 MUX (RAM/ROM) |
| | 74HC138 + 74HC04 | 2 | 控制信号译码 |
| | 39SF040 | 1 | 512KB Flash 波形查找表 |
| | 62256 | 1 | 32KB SRAM 通道寄存器 |
| **总计** | | **12** | |

## SPFM 总线规格

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
3. 地址/数据间隔：≥4 个时钟（推荐 ≥10 clocks = 1µs）

## SPFM 总线接口 (wt_spfm_bus.v)

### 同步链设计

参考 IKAOPLL `rw_synchronizer`，适配单时钟 10MHz：

```
主机 D[7:0]  → 74HC373 透明锁存 → d_latched
主机 CS/WR/A0 → 组合逻辑 → addr_req / data_req
    → 2级 D-FF 同步器 (消除亚稳态)
    → 上升沿检测 → 1-clock 写脉冲 (addr_wr / data_wr)
```

### 与 IKAOPLL 的区别

| 项目 | IKAOPLL (YM2413) | 本设计 |
|------|------------------|--------|
| 时钟 | 3 相 (phiM/phi1/phi1n) | 单时钟 10MHz |
| 脉冲产生 | SR 锁存 + 3 相移位 | 2 级同步 + 边沿检测 |
| 数据锁存 | dlatch (行为级) | 74HC373 (实际芯片) |
| 脉冲宽度 | 1 phase | 1 clock |

### 硬件连接

```
write_synchronizer ×2 (共用 1 片 74HC174):
  sync[0] ← D-FF (posedge CLK, 采样 addr_req/data_req)
  sync[1] ← D-FF (posedge CLK, 消除亚稳态)
  sync_d  ← D-FF (posedge CLK, 延迟 1 拍)
  o_OUT   = sync[1] & ~sync_d  (上升沿 → 1-clock 脉冲)

wt_spfm_bus:
  le        = ~CS_n & ~WR_n & RST_n
  d_latched ← HC373 (LE=le, D=D[7:0])
  addr_req  = ~CS_n & ~WR_n & ~A0
  data_req  = ~CS_n & ~WR_n &  A0
  addr_wr   ← write_synchronizer(addr_req)
  data_wr   ← write_synchronizer(data_req)
  reg_addr  ← HC377 (posedge CLK, addr_wr 时锁存 d_latched)
  reg_data  = d_latched (透传，下游在 data_wr 时采样)
```

### 验证结果（2026-06-13）

| 测试项 | 结果 |
|--------|------|
| CTRL (0x00, 0x02) | PASS: addr=00, data=02 |
| step_lo (0x04, 0x67) | PASS: addr=04, data=67 |
| step_hi (0x05, 0x00) | PASS: addr=05, data=00 |
| note_on (0x06, 0x01) | PASS: addr=06, data=01 |
| 10 次连续写入 | PASS: 全部正确 |
| 复位 | PASS: reg_addr 清零 |

### iverilog 仿真注意事项

1. **透明锁存不能驱动 `zz`**: `always @(*) if(LE) latch = D` 在 D 变化时重新评估，testbench 中保持最后写入值
2. **negedge 驱动**: testbench 用 `@(negedge CLK)` 驱动总线信号，避免 posedge 竞争
3. **SR 锁存组合环**: IKAOPLL 的 SR 锁存 + 3 相时钟在单时钟下产生多 clock 脉冲，改用边沿检测

## RAM 寄存器映射 (62256)

每通道 16 字节, 4通道 = 64 字节 (62256 有 32KB)

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
| ch×16+8 | dac_out | 8 | DAC 输出 |
| ch×16+9 | wave_idx | 3 | 波形选择 0-5 |
| ch×16+10 | env_rate | 8 | 包络速率 |

## 频率参数

```
step = freq × 8192 / sample_rate
sample_rate = 32051 Hz (10MHz / 312 clocks/sample)

常用音符:
C4 (261.6Hz) → step = 67
A4 (440.0Hz) → step = 112
```

## 文件清单

| 文件 | 说明 |
|------|------|
| `rtl/wt_spfm_bus.v` | SPFM 总线接口 (74HC 实例化, 3 IC) |
| `tb/wt_spfm_bus_tb.v` | SPFM 总线测试台 |
| `rtl/wt_ram.v` | 行为级 RAM 架构 (9 IC 方案算法验证) |
| `rtl/wt_rtl.v` | 74HC 门级映射版本 (bit-perfect vs wt_ram) |
| `rom/wt_39sf040.hex` | 512KB 波形 ROM |

## 参考项目

- IKAOPLL (YM2413): `reference/IKAOPLL-main/` — 总线同步链参考
- STC32G 移植版: `D:\working\vscode-projects\STC_Chiptune\STC32G12K128\wt.c` — 频率参数和算法权威参考
- Gigatron TTL: http://gigatron.io/ — 查表 MCU 架构灵感
