# psg_voice 面包板接线表

5 片 74HC PSG + LS373 电平转换 + FT232H 控制器的真实引脚接线。对应 `rtl/psg_voice.v` 和 `Sheet_1_2026-06-30.net`。

## 芯片位置

| 位号 | 型号 | 功能 |
|------|------|------|
| **U0** | **74LS373** | **电平转换层**（FT232H 3.3V → PSG 5V，**实测必需**）|
| U1 | 74HC373 | 8-bit period 锁存（透明锁存器，替代无库存的 HC377） |
| U2 | 74HC161 | 计数器低 4 位 |
| U3 | 74HC161 | 计数器高 4 位 |
| U4 | 74HC00 | 四与非门（1 路 PE 反相 + 2 路 gate 与门） |
| U5 | 74HC74 | 双 D 触发器（半片同步 + 半片 T 翻转） |
| U6 | 排针 PZ254-1-24 | FT232H ↔ PSG 连接器 |
| U7 | 蜂鸣器 | PSG_OUT 输出（建议加 NPN 三极管放大） |
| **控制器** | **FT232H** | PC USB → MPSSE GPIO，D0-D7 数据 + C0-C2 控制 |

> **⚠️ 电平转换层（U0/LS373）是必需的**：
> FT232H 输出 3.3V，74HC 的 VIH=3.5V，直接驱动会被判低（period 不响应、gate 静音、rst 锁死）。
> LS373 的 VIH=2.0V（TTL 输入），能识别 3.3V；由 5V 供电，输出干净 5V 给 74HC。
> 详见 `mcu-interface.md` §1.6 电平兼容性。
>
> **芯片替代**：库存无 HC377，改用 HC373（透明锁存器）。
> HC377 是边沿触发（CLK 沿 + /Enable 锁存）；HC373 是电平敏感（LE 高透明/低锁存），不接 clk。
>
> **芯片合并技巧**：原设计用 HC04（PE 反相）+ HC08（gate 与门）共 2 片。
> 用德摩根律，HC00 一片即可（第 1 路反相 + 第 2/3 路两级与非）。省 1 片。

## 全局信号（来源 + 去向）

**FT232H → LS373 电平转换**：

| FT232H 脚 | LS373 输入 | LS373 输出（5V）| 接到 PSG |
|-----------|-----------|----------------|---------|
| D0-D7 | LS373#1 D0-D7 | Q0-Q7 | period_in[7:0]（U1.D0-D7）|
| C0 (LE) | LS373#1 LE | （锁存控制）| U1.LE（period 锁存使能）|
| C1 (GATE) | LS373#2 D0 | Q0 | U4.A2（gate）|
| C2 (RST) | LS373#2 D1 | Q1 | U2/U3/U5 的 RST 端 |

> LS373#1 的 LE 由 FT232H C0 控制（写 period 时脉冲锁存）；
> LS373#2 的 LE 接 VCC（常透明，纯当电平转换缓冲用）。

**PSG 外部信号**：

| 信号 | 来源 | 去向 |
|------|------|------|
| `clk` | **外部时钟模块**（建议 125kHz，5V） | U2.P2, U3.P2, U5.P3（U1 不接 clk） |
| `wave_out` | U4.P8 | → U7 蜂鸣器 |

## 电源（所有芯片）

| 芯片 | VDD | GND |
|------|-----|-----|
| **74LS373 (U0)** | **Pin 16（5V）** | Pin 8 |
| 74HC373 (U1) | Pin 20 | Pin 10 |
| 74HC161 (U2,U3) | Pin 16 | Pin 8 |
| 74HC00 (U4) | Pin 14 | Pin 7 |
| **74HCT74 (U5)** | Pin 14 | Pin 7（**必须用 HCT，HC 高频失效**）|
| FT232H 模块 | USB 供电 | 与 PSG 共地 |

> 每个 VDD 就近加 0.1μF 去耦电容到 GND。
> **所有 GND 必须共地**：LS373、5 片 74HC、FT232H、外部时钟、蜂鸣器的 GND 全接一条地轨。

---

## U0 — 74LS373（电平转换层，FT232H 3.3V → PSG 5V）

**作用**：把 FT232H 的 3.3V 信号重新锁存成 5V 信号，解决 74HC 的 VIH=3.5V 电平不够问题。

### LS373 #1（period 数据转换，8 位）

| Pin | 信号 | 连接 |
|-----|------|------|
| D0-D7 (P3,4,6,8,13,14,16,18) | ← **FT232H C0-C7**（3.3V）| 数据输入（注：不用 D0-D7，因 D1/D2 MPSSE 不可靠）|
| LE (P11) | ← **FT232H D4**（3.3V 写脉冲）| 锁存使能 |
| /OE (P1) | → GND | 常输出 |
| Q0-Q7 (P2,5,7,9,12,15,17,19) | → U1 (HC373) D0-D7（5V）| 转换后数据 |
| VCC (P20) | → +5V | |
| GND (P10) | → GND | |

### LS373 #2（控制信号转换，用 2-3 位）

| Pin | 信号 | 连接 |
|-----|------|------|
| D0 (P3) | ← **FT232H D5**（GATE，3.3V）| |
| D1 (P4) | ← **FT232H D6**（RST，3.3V）| |
| LE (P11) | → VCC（常透明，纯缓冲）| 永远跟随 |
| /OE (P1) | → GND | 常输出 |
| Q0 (P2) | → U4.A2（gate，5V）| |
| Q1 (P5) | → U2/U3/U5 RST（rst_n，5V）| |
| VCC (P20) | → +5V | |
| GND (P10) | → GND | |

> LS373 #2 用 LE=VCC 常透明模式，gate/rst 实时跟随 FT232H，纯当电平转换用。

---

## FT232H 控制器接线（USB → PSG）

FT232H 用 MPSSE 模式（D2XX）。**注意引脚陷阱**：ADBUS D0-D3 是 SPI 专用，D1/D2 写 0 会被强制拉高，**不可靠**。所以 period 数据用 ACBUS C0-C7，控制信号用 D4-D6：

| FT232H 脚 | MPSSE 命令 | PSG 信号 | 接到 | 说明 |
|-----------|-----------|---------|------|------|
| C0 (ACBUS0) | 0x82 bit0 | period_in[0] | LS373#1.D0 | 数据位 0 |
| C1 (ACBUS1) | 0x82 bit1 | period_in[1] | LS373#1.D1 | 数据位 1 |
| C2 (ACBUS2) | 0x82 bit2 | period_in[2] | LS373#1.D2 | 数据位 2 |
| C3 (ACBUS3) | 0x82 bit3 | period_in[3] | LS373#1.D3 | 数据位 3 |
| C4 (ACBUS4) | 0x82 bit4 | period_in[4] | LS373#1.D4 | 数据位 4 |
| C5 (ACBUS5) | 0x82 bit5 | period_in[5] | LS373#1.D5 | 数据位 5 |
| C6 (ACBUS6) | 0x82 bit6 | period_in[6] | LS373#1.D6 | 数据位 6 |
| C7 (ACBUS7) | 0x82 bit7 | period_in[7] | LS373#1.D7 | 数据位 7 |
| D4 (ADBUS4) | 0x80 bit4 | period_le | LS373#1.LE | LE 写脉冲（HC373 锁存） |
| D5 (ADBUS5) | 0x80 bit5 | gate | LS373#2.D0 → U4.P4 | 门控（1=发声） |
| D6 (ADBUS6) | 0x80 bit6 | rst_n | LS373#2.D1 → U2/U3/U5 RST | 复位（低有效） |
| D0-D3, D7 | - | 备用 | - | D0-D3 是 SPI 专用不可靠，不用 |

> ⚠️ **为什么 period 用 C 口不用 D 口**：ADBUS 的 D0-D3 是 MPSSE 的 SPI 引脚（TCK/TDI/TDO/TMS），**D1/D2 写 0 会被强制拉高**，导致 period 数据被篡改。ACBUS C0-C7 完全可控。
> **电平注意**：FT232H 是 **3.3V 输出**，经 LS373 转换成 5V 后驱动 PSG。
> **GND 共地**：FT232H 模块的 GND 必须接到 PSG 的 GND 总线。

---

## U1 — 74HC373（period 锁存，透明锁存器）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | `/OE` | **GND**（常输出，不接高阻） |
| 11 | `LE` | **period_le**（写使能，= ~WE，高有效脉冲） |
| 3 | D0 | period_in[0]（host） |
| 4 | D1 | period_in[1]（host） |
| 6 | D2 | period_in[2]（host） |
| 8 | D3 | period_in[3]（host） |
| 13 | D4 | period_in[4]（host） |
| 14 | D5 | period_in[5]（host） |
| 16 | D6 | period_in[6]（host） |
| 18 | D7 | period_in[7]（host） |
| 2 | Q0 | → U2.P3（D0） |
| 5 | Q1 | → U2.P4（D1） |
| 7 | Q2 | → U2.P5（D2） |
| 9 | Q3 | → U2.P14（D3） |
| 12 | Q4 | → U3.P3（D0） |
| 15 | Q5 | → U3.P4（D1） |
| 17 | Q6 | → U3.P5（D2） |
| 19 | Q7 | → U3.P14（D3） |
| 20 | VDD | +5V |
| 10 | GND | GND |

> **HC373 写时序**：MCU 把数据放 D[7:0] → LE 拉高（Q 跟随）→ 保持 ≥0.1μs → LE 拉低（锁存）。
> 无需关心 PSG 的 125kHz clk 相位，LE 任意时刻拉低都能锁住当前 D 值。

---

## U2 — 74HC161（计数器低 4 位，count[3:0]）

> count[0:3] 的 Q 引脚仅被芯片**内部** TC 判满逻辑使用（`TC = CET & (Q==0xF)`），
> 外部无下游负载 → **Q0-Q3 可悬空**，留作示波器/LED 观测用。

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | `MR` | **rst_n** |
| 2 | `CP` | **clk** |
| 3 | D0 | U1.Q0（P18） |
| 4 | D1 | U1.Q1（P16） |
| 5 | D2 | U1.Q2（P14） |
| 14 | D3 | U1.Q3（P12） |
| 6 | Q0 | count[0]（悬空 / 观测） |
| 11 | Q1 | count[1]（悬空 / 观测） |
| 12 | Q2 | count[2]（悬空 / 观测） |
| 13 | Q3 | count[3]（悬空 / 观测） |
| 7 | `CEP` | +5V（始终使能） |
| 10 | `CET` | +5V（始终使能） |
| 9 | `PE` | **pe_n**（U4.P3，HC00 第 1 路 Y1） |
| 15 | `TC` | → U3.P7, U3.P10（级联使能高位） |
| 16 | VDD | +5V |
| 8 | GND | GND |

---

## U3 — 74HC161（计数器高 4 位，count[7:4]）

> count[4:7] 的 Q 引脚同上，仅内部 TC 判满用，**外部悬空 OK**。
> 注意 U3 的 **TC（P15）必须外接**（驱动 PE 反相 + sync）。

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | `MR` | **rst_n** |
| 2 | `CP` | **clk** |
| 3 | D0 | U1.Q4（P9） |
| 4 | D1 | U1.Q5（P7） |
| 5 | D2 | U1.Q6（P5） |
| 14 | D3 | U1.Q7（P8） |
| 6 | Q0 | count[4]（悬空 / 观测） |
| 11 | Q1 | count[5]（悬空 / 观测） |
| 12 | Q2 | count[6]（悬空 / 观测） |
| 13 | Q3 | count[7]（悬空 / 观测） |
| 7 | `CEP` | U2.TC（P15） |
| 10 | `CET` | U2.TC（P15） |
| 9 | `PE` | **pe_n**（U4.P3，HC00 第 1 路 Y1） |
| 15 | `TC` | → **tc_hi**：U4.P1,P2（HC00 第 1 路 A1,B1）；U5.P2（sync D1） |
| 16 | VDD | +5V |
| 8 | GND | GND |

---

## U4 — 74HC00（四 2 输入与非门）

一片同时完成 PE 反相 + gate 与门（合并原 HC04 + HC08）：

| 路 | 功能 | 逻辑 |
|----|------|------|
| 第 1 路 (P1,2,3) | PE 反相 | `pe_n = ~(tc_hi & tc_hi) = ~tc_hi`（A1,B1 短接当反相器） |
| 第 2 路 (P4,5,6) | gate 与门第一级 | `gate_nand1 = ~(gate & toggle_q)` |
| 第 3 路 (P9,10,8) | gate 与门第二级 | `wave_out = ~(gate_nand1 & gate_nand1) = gate & toggle_q` |
| 第 4 路 (P12,13,11) | 闲置 | 接 GND |

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | A1 | U3.TC（P15）= **tc_hi** |
| 2 | B1 | U3.TC（P15）= **tc_hi**（与 A1 短接） |
| 3 | Y1 | → **pe_n** → U2.P9, U3.P9 |
| 4 | A2 | **gate**（host 门控） |
| 5 | B2 | U5.Q2（P9）= **toggle_q** |
| 6 | Y2 | → **gate_nand1** → U4.P9, U4.P10（自反馈到第 3 路输入） |
| 9 | A3 | U4.Y2（P6）= **gate_nand1**（与 B3 短接） |
| 10 | B3 | U4.Y2（P6）= **gate_nand1**（与 A3 短接） |
| 8 | Y3 | → **wave_out**（DAC / 喇叭） |
| 12 | A4 | 接 GND（不用） |
| 13 | B4 | 接 GND（不用） |
| 11 | Y4 | 悬空 |
| 14 | VDD | +5V |
| 7 | GND | GND |

> ⚠️ **第 3 路输入短接**：A3、B3 都接 Y2（gate_nand1），两级与非实现正与门。
> 第 1 路 A1、B1 都接 tc_hi，输入短接当反相器。

---

## U5 — 74HC74（双 D 触发器：半片 sync + 半片 toggle）

- **第 1 半（Pin 1-6）= sync**：D 触发器，用 clk 同步 tc_hi 消毛刺 → reload_pulse
- **第 2 半（Pin 8-13）= toggle**：T 触发器，reload_pulse 上升沿翻转 → toggle_q

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | `CLR1`（sync） | **rst_n** |
| 2 | D1（sync） | U3.TC（P15）= **tc_hi** |
| 3 | CLK1（sync） | **clk** |
| 4 | `PRE1`（sync） | +5V（不置位） |
| 5 | Q1（sync） | → **reload_pulse** → U5.P11（toggle 的 CLK2） |
| 6 | Q1_n（sync） | 悬空（观测点） |
| 7 | GND | GND |
| 8 | Q2_n（toggle） | → U5.P12（**自反馈接成 T 触发器**） |
| 9 | Q2（toggle） | **toggle_q** → U4.P5（HC00 第 2 路 B2） |
| 10 | `PRE2`（toggle） | +5V（不置位） |
| 11 | CLK2（toggle） | U5.Q1（P5）= **reload_pulse** |
| 12 | D2（toggle） | U5.Q2_n（P8） |
| 13 | `CLR2`（toggle） | **rst_n** |
| 14 | VDD | +5V |

> ⚠️ **关键**：toggle 半片接成 T 触发器 —— 把 **Q2_n（P8）接到 D2（P12）**。

---

## 关键 net 汇总（飞线清单）

**FT232H 控制信号（来自控制器）**：

| net 名 | 来源 | 连接点 |
|--------|------|--------|
| **period_in[7:0]** | FT232H D0-D7 | U1.P3,4,6,8,13,14,16,18 |
| **period_le** | FT232H C0 | U1.11 |
| **gate** | FT232H C1 | U4.4 |
| **rst_n** | FT232H C2 | U2.1, U3.1, U5.1, U5.13 |
| **clk** | 外部时钟模块（125kHz） | U2.2, U3.2, U5.3（U1 不接） |

**PSG 内部信号（片间互连）**：

| net 名 | 定义 | 连接点 |
|--------|------|--------|
| **tc_lo** | 低位进位 | U2.15 → U3.7, U3.10 |
| **tc_hi** | 8-bit 计满 | U3.15 → U4.1, U4.2；U5.2 |
| **pe_n** | 重装控制（=~tc_hi） | U4.3 → U2.9, U3.9 |
| **gate_nand1** | gate 与门中间量 | U4.6 → U4.9, U4.10 |
| **reload_pulse** | 同步后的重装脉冲 | U5.5 → U5.11 |
| **toggle_q** | 方波（T 触发器输出） | U5.9 → U4.5 |
| **T 反馈** | toggle 半片自反馈 | U5.8 → U5.12（Q2_n→D2） |

**输出**：

| net 名 | 来源 | 连接点 |
|--------|------|--------|
| **wave_out** | U4.8 | → U7 蜂鸣器（建议串 NPN 三极管放大） |

## GND 共地（关键）

**FT232H 模块的 GND 必须接到 PSG 的 GND 总线**，否则所有信号无参考电平，PSG 不工作。
建议在面包板上用一整条地轨，FT232H 的 GND、5 片 74HC 的 GND、外部时钟 GND、蜂鸣器 GND 全接到这条地轨。

## HC00 合并原理（为什么能省一片）

需要两个功能：① `pe_n = ~tc_hi`（反相）② `wave_out = gate & toggle_q`（与门）。

用 HC00（与非门）一片搞定：
- **反相**：与非门两输入短接 = 反相器。`Y = ~(A & A) = ~A`。第 1 路：`pe_n = ~(tc_hi & tc_hi)`
- **与门**：两级与非 = 正与门。`Y2 = ~(gate & toggle_q)`，`Y3 = ~(Y2 & Y2) = gate & toggle_q`

HC00 有 4 路：第 1 路反相 + 第 2/3 路与门 = 3 路，第 4 路闲置。仿真已验证（A4=440Hz, A5=880Hz 精确，gate 开关正常）。

> 同理可用 HC02（或非门）实现，但需调整 toggle 输出极性（用 Q_n）。本设计选 HC00，保留 toggle 用 Q（非反相）。
