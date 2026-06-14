# 一通道可调频率方波 (sq_top) — 最小可用架构

从最简单开始：单通道方波蜂鸣器，无 ROM、无 RAM、无 DAC。验证 74HC 数据通路能跑、能听。

## 设计目标

- 100% 芯片实例化（无 reg 冒充，无隐藏 assign 逻辑门）
- 输出 50% 占空比方波
- 主时钟 1.789773 MHz（PSG 标准，对齐 SN76489）
- 频率可编程，覆盖全音域
- **输出直接接喇叭**（经耦合电容），不需要 DAC

## 频率公式

```
f_out = SPFM_CLK / [2 × (65536 - FREQ)]
```

| FREQ | 周期 STEP | f_out | 音名 |
|---|---|---|---|
| 0 | 65536 | 13.65 Hz | C1 |
| 49152 | 16384 | 54.6 Hz | A1 |
| 63488 | 2048 | 437 Hz | A4 |
| 65280 | 256 | 3495 Hz | A7 |
| 65535 | 1 | 894 kHz | 上限 |

C4 261.6 Hz @ 1.789773 MHz: `FREQ = 65536 - 3419 = 0xF2A5`

## 架构

```
SPFM 总线 → 373/174/377 (3 IC) → reg_addr/reg_data
                                         ↓
                                  hc32 译码 Enable_bar
                                         ↓
                              hc377 ×2 (频率字低/高字节)
                                         ↓
                              hc161 ×4 (16位可编程计数器)
                                         ↓
                                   TC3 → hc04 → pe_n (预置)
                                         ↓
                                   TC3 → hc74 (T 触发器)
                                         ↓
                                      sq_out → 喇叭
```

## 主机接口 (SPFM)

主机连续写两次（addr + data）：

| 顺序 | A0 | D[7:0] | 说明 |
|---|---|---|---|
| 1 | 0 | 0x00 / 0x01 | 写地址（选择低/高字节）|
| 2 | 1 | freq_lo / freq_hi | 写数据 |

`wt_spfm_bus` 模块解码出 `addr_wr`、`data_wr` 脉冲。`data_wr` 触发时根据 `reg_addr[0]` 选择写入 `freq_lo` 或 `freq_hi`。

## 芯片清单 (12 IC)

| 部分 | 芯片 | 数量 | 用途 |
|---|---|---|---|
| **SPFM 总线** | 74HC373 | 1 | D[7:0] 透明锁存 |
| | 74HC174 | 1 | 两路同步器 |
| | 74HC377 | 1 | 地址寄存器 |
| **频率字锁存** | 74HC377 | 2 | freq_lo, freq_hi |
| **16位计数器** | 74HC161 | 4 | 可编程分频器 |
| **T 触发器** | 74HC74 | 1 | 50% 方波输出 |
| **门电路** | 74HC04 | 1 | pe_n + data_wr_n + a0n |
| | 74HC32 | 1 | Enable_bar 译码 |
| **合计** | | **12** | |

## 关键文件

- [rtl/sq_top.v](../rtl/sq_top.v) — 顶层
- [rtl/wt_spfm_bus.v](../rtl/wt_spfm_bus.v) — SPFM 总线
- [rtl/hc161.v](../rtl/hc161.v), [hc377.v](../rtl/hc377.v), [hc74.v](../rtl/hc74.v), [hc04.v](../rtl/hc04.v), [hc32.v](../rtl/hc32.v) — 芯片模型
- [tb/sq_tb.v](../tb/sq_tb.v) — 测试（C4 0.5 秒）
- [rom/sq2wav.py](../rom/sq2wav.py) — CSV → WAV 转换

## 仿真验证

```
$ iverilog -g2012 -o sq.vvp rtl/sq_top.v rtl/wt_spfm_bus.v \
    rtl/hc161.v rtl/hc377.v rtl/hc74.v rtl/hc04.v rtl/hc32.v \
    tb/sq_tb.v
$ vvp sq.vvp
$ python rom/sq2wav.py
```

输出 `sq_output.wav`，0.5 秒 C4 方波，可用 Audacity 试听。

## 启动期

计数器从 0 数到 0xFFFF 需要 65536 STEP ≈ 36.6 ms。仿真前 36 ms 输出恒为 0，之后开始正常翻转。**硬件实际工作时也有这个启动期**（开机后 36 ms 静音）。

若需要消除启动期，可以加 MR 复位逻辑（启动时把计数器预置到 FREQ）。

## 实例化审查

无任何隐藏门：
- `assign sq_out = sq_q` — wire 直连（PCB 导线）
- 所有 `& | ~ !` 运算符都在芯片模型内部（hc04 的 `~`、hc32 的 `|`、hc161 内部 `&&`、hc74/hc377 的 `!` 都是芯片功能描述）

## 下一步扩展路径

1. **加音量控制** — 输出端加模拟开关 + 电阻分压（不增加数字 IC）
2. **加包络** — 用 rc 充放电或 attack/decay 计数器
3. **扩展到 3 通道方波** — 复制本架构 × 3 + 输出端或混合
4. **加噪音通道** — LFSR（74HC164 + 异或门）
5. **加波形 ROM** — 变成 DDS 波表合成器（升级回 WSG 风格）
