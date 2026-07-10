# PSG3 v0.5 接线表 — 波形通道

> v0.5 核心通道. 一个 CD4029 4-bit 计数器, wave_sel 切换 4 种波形.
> HC283 加法器(做比较) + HC08 AND 门双路径, mode_sel 1-bit 切换音色调制方式.
> 周期分两类: 锯齿族单向16步 (fold=0) / 三角折返30步 (fold=1).
>   锯齿族: freq = 4MHz / (16 × (4096 - period12))
>   三角:   freq = 4MHz / (30 × (4096 - period12))
> 仿真验证: `tb/psg3_uni_tb.v` (方波/三角/锯齿/反锯齿/比较/AND/噪音, 0 错误)

---

## 一、原理

```
3×HC161 (period12 上计数) → freq_tc (每 (4096-p12) clk 一个脉冲)
                                    │
                     freq_tc → CD4029 (4-bit 计数器, CI=~freq_tc)
                                    │ Q0-3 (4-bit 计数值)
                     ┌──────────────┴──────────────────────┐
                     │ HC273 (滤毛刺) Q0-3 干净            │
                     │    ┌────────────────┬───────────────┤
                     │    │ HC283 (比较)   │ HC08 (AND)    │
                     │    │ Q<duty → 15/0  │ Q & duty      │
                     │    └───────┬────────┴───────┬───────┘
                     └──── HC157 选 ───────────────┘
                              │ wave_sel + mode_sel 控制
                    TLC7524#1 (波形) → TLC7524#2 (音量) → 喇叭
```

**波形切换** (wave_sel 2-bit = dir+fold, mode_sel 1-bit):
```
wave_sel | dir|fold| 波形   | CD4029 行为        | 周期  | HC157 选
---------|----|----|--------|-------------------|-------|----------
  00     | 0  | 0  | 锯齿   | 单向加 0→15→0      | 16步  | mode_sel 选
  01     | -  | 1  | 三角   | HC112折返 0→15→0   | 30步  | mode_sel 选
  10     | 0  | 0  | 方波   | 单向加 0→15→0      | 16步  | 固定比较 (占空比)
  11     | 1  | 0  | 反锯齿 | 单向减 15→0→15     | 16步  | mode_sel 选
```

周期分两类 (核心: wave_sel[0]=fold 控制有无 HC112 折返):
- 锯齿族 (fold=0): 单向回绕, 16步/周期, freq=4M/(16×(4096-p12))
- 三角 (fold=1): HC112 折返, 30步/周期, freq=4M/(30×(4096-p12))

方波 = 锯齿底子 (fold=0+dir=0) + 强制走 HC283 比较 (mode_sel 无效).
mode_sel 只对三角/锯齿/反锯齿有效 (方波固定比较).

**duty4 = 音色调制参数**:
- 方波: duty 控占空比 (duty=8 → 50%)
- 三角/锯齿 mode_sel=1: HC283 比较 (阈值调制, 波形削顶 → 加奇次谐波)
- 三角/锯齿 mode_sel=0: HC08 AND (位掩码, 降精度 → 加量化高频)
- 同一个 duty4 值, 两种模式产生不同音色效果

---

## 二、寄存器 (24 bit = 3 reg)

```
reg3 (0x08): period12[7:0]
reg4 (0x10): period12[11:8] | vol[3:0]        ← 频率+音量
reg5 (0x20): duty[3:0] | wave_sel[1:0] | mode_sel | 预留  ← 音色
  duty4: 比较阈值/AND掩码 (音色调制参数)
  wave_sel[1] = dir  (0=加=锯齿/方波, 1=减=反锯齿)
  wave_sel[0] = fold (0=单向16步=锯齿族, 1=折返30步=三角)
  → wave_sel 编码: 00锯齿 01三角 10方波 11反锯齿
  方波 = dir=0 + fold=0 + 强制走 HC283 比较 (mode_sel 无效)
  mode_sel: 1=HC283比较(阈值调制) 0=HC08 AND(位掩码调制)
```

### 音高公式（两套，按波形周期）

```
锯齿族 (16步): freq = 4000000 / (16 × (4096 - period12))
三角 (30步):  freq = 4000000 / (30 × (4096 - period12))
period12 = {reg4[7:4], reg3[7:0]} = 12-bit

锯齿族覆盖: B1(61Hz)~C8(4186Hz), 74/85音<1%, 最差C8=0.46%
三角覆盖:   C1(32.7Hz)~C8(4186Hz), 84/85音<1%, G7=1.12%最差
查找表: host/uni_period_table.h (uni_period12_saw / uni_period12_tri, 穷举优化)
```

---

## 三、芯片清单 (14 片 + 3 寄存器属总线层)

> 波形通道自包含, 不借接口层任何芯片. ~clk 由本通道 U33 HC04 提供.

| 位号 | 型号 | 功能 |
|------|------|------|
| R3(=总线U5) | 74HC374 | reg3: 波形 period12[7:0] (属总线层, 逐脚见下) |
| R4(=总线U6) | 74HC374 | reg4: 波形 period12[11:8] \| vol[3:0] |
| R5(=总线U7) | 74HC374 | reg5: 波形 duty \| wave_sel \| mode_sel |
| U20 | 74HC161 | period12 低 4 位 |
| U21 | 74HC161 | period12 中 4 位 |
| U22 | 74HC161 | period12 高 4 位 (TC=freq_tc) |
| U23 | 74HC00 | **4门全用**: PE反相 / ~CO / ~dir / ~fold |
| U24 | CD4029 | **4-bit 波形计数器** (CI=~freq_tc, UD=fold折返/单向) |
| U25 | 74HC112 | 折返方向控制 (下降沿JK, 替代CD4027, 库存有) |
| U26 | 74HC283 | **4-bit 加法器做比较** (duty-counter看进位, 替代HC85, 库存有) |
| U27 | 74HC08 | **4-bit AND** (counter AND duty → 位掩码调制) |
| U28 | 74HC157 | **四 2选1** (mode_sel 选 AND/比较, 4 路独立, 库存有) |
| U29 | 74HC273 | 毛刺滤除 (4-bit, clk 反相沿) |
| U30 | TLC7524 | #1 波形生成 (DB4-7, REF=5V) |
| U31 | TLC7524 | #2 音量衰减 (DB4-7=vol4, REF=#1输出) |
| U32 | 74HC00 | **4门全用**: uni_ud mux (3门) + ~rst_n (门4) |
| U33 | 74HC04 | **clk 反相** (~clk 给 HC112 CLK1 (但112直连clk,实际不给) + HC273 CP, 用1门) |

> R3/R4/R5 物理上是总线层的 U5/U6/U7 (HC374 寄存器), 电源/CP/OE 在 wiring-table-bus.md.
> 本表只标它们 Q 脚的去向 (到波形通道各芯片). 通道层本身 13 片 (U20-U32).

---

## 四、逐芯片接线

### R3/R4/R5 — 74HC374×3 (波形通道数据寄存器, reg3/4/5)

> 这 3 片 HC374 属于总线层 (物理位号 U5/U6/U7), 本表标 R3/R4/R5 以示区别.
> 逐脚接线与总线层所有 HC374 相同 (D/Q 交错排列), 只是 Q 去向不同.
> ⚠️ HC374 D/Q 交错排列 (Nexperia datasheet 核对):
> D0-D7 = P3,4,7,8,13,14,17,18；Q0-Q7 = P2,5,6,9,12,15,16,19.

**3 片通用引脚 (输入全接总线 D0-D7):**

| Pin | 信号 | 来源 |
|-----|------|------|
| 1 (/OE) | → GND | 常输出 |
| 3 (D0) | ← 总线 D0 | FT232H C0 经 LS373 电平转换 |
| 4 (D1) | ← 总线 D1 | FT232H C1 |
| 7 (D2) | ← 总线 D2 | FT232H C2 |
| 8 (D3) | ← 总线 D3 | FT232H C3 |
| 13 (D4) | ← 总线 D4 | FT232H C4 |
| 14 (D5) | ← 总线 D5 | FT232H C5 |
| 17 (D6) | ← 总线 D6 | FT232H C6 |
| 18 (D7) | ← 总线 D7 | FT232H C7 |
| 20 | VCC → +5V | |
| 10 | GND | |

> 总线 D0-D7 来自接口层 U0a (74LS373 电平转换), 8 片 HC374 的 D 全并联接同一总线.
> CP 来自总线层地址译码 (HC08 选通, 见 wiring-table-bus.md).

**R3 (reg3 = 波形 period12[7:0])**：CP=P11 ← reg_cp[3] (总线层 U12.Y4)

| Q Pin | 信号 | 去向 |
|-------|------|------|
| 2 (Q0) | period12[0] | → U20.D0 (HC161 低 4 位) |
| 5 (Q1) | period12[1] | → U20.D1 |
| 6 (Q2) | period12[2] | → U20.D2 |
| 9 (Q3) | period12[3] | → U20.D3 |
| 12 (Q4) | period12[4] | → U21.D0 (HC161 中 4 位) |
| 15 (Q5) | period12[5] | → U21.D1 |
| 16 (Q6) | period12[6] | → U21.D2 |
| 19 (Q7) | period12[7] | → U21.D3 |

**R4 (reg4 = 波形 period12[11:8] | vol[3:0])**：CP=P11 ← reg_cp[4] (总线层 U13.Y1)

| Q Pin | 信号 | 去向 |
|-------|------|------|
| 2 (Q0) | vol[0] | → U31.DB4 (TLC7524#2 音量) |
| 5 (Q1) | vol[1] | → U31.DB5 |
| 6 (Q2) | vol[2] | → U31.DB6 |
| 9 (Q3) | vol[3] | → U31.DB7 |
| 12 (Q4) | period12[8] | → U22.D0 (HC161 高 4 位) |
| 15 (Q5) | period12[9] | → U22.D1 |
| 16 (Q6) | period12[10] | → U22.D2 |
| 19 (Q7) | period12[11] | → U22.D3 |

**R5 (reg5 = 波形 duty[3:0](bit0-3) | mode_sel(bit4) | wave_sel[1:0](bit5-6) | 预留(bit7))**：CP=P11 ← reg_cp[5] (总线层 U13.Y2)

| Q Pin | 信号 | 去向 |
|-------|------|------|
| 2 (Q0) | duty[0] | → U26 HC283 A1 + U27 HC08 门1B |
| 5 (Q1) | duty[1] | → U26 HC283 A2 + U27 HC08 门2B |
| 6 (Q2) | duty[2] | → U26 HC283 A3 + U27 HC08 门3B |
| 9 (Q3) | duty[3] | → U26 HC283 A4 + U27 HC08 门4B |
| 12 (Q4) | mode_sel | → U28 HC157 P1 (Select, 选比较/AND) |
| 15 (Q5) | wave_sel[0]=fold | → U23 门4 (fold 反相器输入) |
| 16 (Q6) | wave_sel[1]=dir | → U23 门3 (dir 反相器输入) |
| 19 (Q7) | 预留 | 悬空 |

> R3/R4/R5 的 D0-D7 全接同一总线 (FT232H 写入时由 CP 选通哪片锁存).
> duty[0-3] 各自扇出到 HC283 和 HC08 两处 (同一根线接两个芯片输入).

---

### U20-U22 — 74HC161×3 (period12 上计数器)

> 74HC161 DIP-16 引脚 (据 Nexperia/TI datasheet 核对):
> P1=MR P2=CP P3=P0 P4=P1 P5=P2 P6=P3 P7=CEP P8=GND P9=PE P10=CET P11=Q3 P12=Q2 P13=Q1 P14=Q0 P15=TC P16=VCC

**U20 (低位, period12[3:0]):**

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 (MR) | ← rst_n | 复位 (低有效) |
| 2 (CP) | ← clk (4MHz) | 计数时钟 |
| 3 (P0) | ← R3.Q0 (period12[0]) | 预置 bit0 |
| 4 (P1) | ← R3.Q1 (period12[1]) | 预置 bit1 |
| 5 (P2) | ← R3.Q2 (period12[2]) | 预置 bit2 |
| 6 (P3) | ← R3.Q3 (period12[3]) | 预置 bit3 |
| 7 (CEP) | → +5V | 常使能 |
| 8 (GND) | → GND | |
| 9 (PE) | ← U23.Y1 (P3, ~freq_tc) | 计满预置 (3 片共用) |
| 10 (CET) | → +5V | 常使能 |
| 11-14 (Q3-Q0) | 悬空 | (只内部 TC 用) |
| 15 (TC) | → U21.CEP(P7), U21.CET(P10) | **级联高位** |
| 16 (VCC) | → +5V | |

**U21 (中位, period12[7:4]):**

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 (MR) | ← rst_n | |
| 2 (CP) | ← clk | |
| 3 (P0) | ← R3.Q4 (period12[4]) | |
| 4 (P1) | ← R3.Q5 (period12[5]) | |
| 5 (P2) | ← R3.Q6 (period12[6]) | |
| 6 (P3) | ← R3.Q7 (period12[7]) | |
| 7 (CEP) | ← U20.TC (P15) | 级联使能 |
| 8 (GND) | → GND | |
| 9 (PE) | ← U23.Y1 (P3, ~freq_tc) | 共用预置 |
| 10 (CET) | ← U20.TC (P15) | 级联使能 |
| 11-14 (Q3-Q0) | 悬空 | |
| 15 (TC) | → U22.CEP(P7), U22.CET(P10) | **级联高位** |
| 16 (VCC) | → +5V | |

**U22 (高位, period12[11:8], TC=freq_tc):**

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 (MR) | ← rst_n | |
| 2 (CP) | ← clk | |
| 3 (P0) | ← R4.Q4 (period12[8]) | |
| 4 (P1) | ← R4.Q5 (period12[9]) | |
| 5 (P2) | ← R4.Q6 (period12[10]) | |
| 6 (P3) | ← R4.Q7 (period12[11]) | |
| 7 (CEP) | ← U21.TC (P15) | 级联使能 |
| 8 (GND) | → GND | |
| 9 (PE) | ← U23.Y1 (P3, ~freq_tc) | 共用预置 |
| 10 (CET) | ← U21.TC (P15) | 级联使能 |
| 11-14 (Q3-Q0) | 悬空 | |
| 15 (TC) | → **freq_tc** (= U23 门1 输入 + 赋给 uni_freq_tc) | **最高位进位=频率脉冲** |
| 16 (VCC) | → +5V | |

### U23 — 74HC00 (4 门全用: 反相器组)

> HC00 DIP-14: 门1=P1(A)/P2(B)/P3(Y) 门2=P4(A)/P5(B)/P6(Y) 门3=P9(A)/P10(B)/P8(Y) 门4=P12(A)/P13(B)/P11(Y). P14=VCC P7=GND.
> 反相器接法: A 和 B (P1+P2 等) 接同一信号, Y = ~(A·A) = ~A.

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 (A1) | ← freq_tc (U22.P15) | 门1输入 (短接P2) |
| 2 (B1) | ← freq_tc (与P1短接) | 门1输入 |
| 3 (Y1) | **→ ~freq_tc** | → U20-22.PE (P9, 3片共用) |
| 4 (A2) | ← CO (U24.P7) | 门2输入 (短接P5) |
| 5 (B2) | ← CO (与P4短接) | 门2输入 |
| 6 (Y2) | **→ ~CO (at_extreme)** | → U25.P2 (1K), U25.P3 (1J) |
| 7 (GND) | → GND | |
| 8 (Y3) | **→ ~dir** | → U32.P4 (门2 A 输入) |
| 9 (A3) | ← dir (R5.Q3, reg5 bit3) | 门3输入 (短接P10) |
| 10 (B3) | ← dir (与P9短接) | 门3输入 |
| 11 (Y4) | **→ ~fold** | → U32.P5 (门2 B 输入) |
| 12 (A4) | ← fold (R5.Q2, reg5 bit2) | 门4输入 (短接P13) |
| 13 (B4) | ← fold (与P12短接) | 门4输入 |
| 14 (VCC) | → +5V | |

> 门2的 ~CO 直接当 at_extreme (给 HC112 的 J/K). 不需要额外 AND —— CD4029 CO 真值表已含 CI=freq_tc 条件.

### U24 — CD4029 (4-bit 波形计数器)

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 (PE) | → GND | 不预置 |
| 2 (Q4) | → U29.P8 (D3) | Q4=bit3(MSB) → HC273 D3 |
| 3 (J4) | → GND | 预置位4(MSB) 不用 |
| 4 (J1) | → GND | 预置位1(LSB) 不用 |
| 5 (Cin) | ← **~freq_tc (U23 门1, 与 HC161 的 PE 同一根线)** | freq_tc=H(CI=L) 时走一步 |
| 6 (Q1) | → U29.P3 (D0) | Q1=bit0(LSB) → HC273 D0 |
| 7 (Cout) | → **U23 门2 (反相成 ~CO = at_extreme)** → U25 J/K | 极值信号 (仅三角折返用) |
| 8 (VSS) | → GND | |
| 9 (B/D) | → +5V | 二进制 |
| 10 (U/D) | ← **uni_ud (U32 门3 mux 输出)** | 方向: fold=1三角折返 / fold=0单向(~dir) |
| 11 (Q2) | → U29.P4 (D1) | Q2=bit1 → HC273 D1 |
| 12 (J2) | → GND | 预置位2 不用 |
| 13 (J3) | → GND | 预置位3 不用 |
| 14 (Q3) | → U29.P7 (D2) | Q3=bit2 → HC273 D2 |
| 15 (CLK) | ← **clk (4MHz)** | 连续时钟 |
| 16 (VDD) | → +5V | |

> CD4029 按 UD 加/减, CI=L(freq_tc) 时走一步. 周期由 fold 决定:
> fold=0 (锯齿族): 单向回绕 (加到15→0 或 减到0→15), 16步/周期
> fold=1 (三角): HC112 控制 UD 折返 (0→15→0), 30步/周期

### U25 — 74HC112 (折返方向控制, 下降沿 JK 触发器)

> CD4027 不在库存, 用 74HC112 替代 (库存有).
> 112 是下降沿触发 + PRE/CLR 低有效, 与 CD4027 (上升沿/SET-RST高有效) 引脚完全不同.
> 引脚据 TI SN74HC112 datasheet (hc112.v 注释已标来源).

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 (1CLK) | ← **clk (4MHz, 直连不反相)** | 112 下降沿触发, 在 clk 下降沿采样 |
| 2 (1K) | ← **~CO (U23 门2 = at_extreme)** | 极值时 toggle |
| 3 (1J) | ← **~CO (U23 门2 = at_extreme)** | J=K 同接, toggle 模式 |
| 4 (1PRE) | → +5V | 置位无效 (高=不置位) |
| 5 (1Q) | → (备用, dir_q) | 正输出 |
| 6 (1Q_n) | → **U32 门1 (dir_qn)** | mux 输入 (三角折返方向) |
| 7 (1CLR) | ← **rst_n (直连!)** | 清零低有效, rst_n 低有效, **直连不需反相** |
| 8 (GND) | → GND | |
| 16 (VCC) | → +5V | |
| 9 (2PRE) | → +5V | 触发器2 置位无效 |
| 10 (2CLR) | → +5V | 触发器2 清零无效 |
| 11 (2Q) | 悬空 | 触发器2 输出不用 |
| 12 (2Q_n) | 悬空 | 触发器2 反相输出不用 |
| 13 (2K) | → GND | 触发器2 输入接地 |
| 14 (2J) | → GND | 触发器2 输入接地 |
| 15 (2CLK) | 悬空 | 触发器2 时钟不用 |

> ⚠️ **112 vs CD4027 三大区别** (上板别接错):
> 1. 112 下降沿触发 → CLK 直接连 clk (CD4027 要接 ~clk)
> 2. 112 CLR 低有效 → 直接连 rst_n (CD4027 RST 高有效要接 ~rst_n, **省了 U32 门4 反相器**)
> 3. 112 PRE/CLR 都是低有效, PRE 接 +5V 使其无效 (CD4027 SET 接 GND)

> **at_extreme = ~CO** (不用额外 AND 门):
> CD4029 CO 真值表已含 CI 条件, ~CO=H 隐含 freq_tc=H. 直接用 U23门2 输出.
> **112 一直转, mux 选 UD**: fold=0 时 U32 mux 不选 dir_qn (选 ~dir), 112 白转无害.

**uni_ud 真值表** (U32 mux 实现):
```
fold | uni_ud 来源        | 波形
-----|-------------------|-----
  0  | ~dir (U23门3)      | 锯齿(dir=0→UD=1) / 反锯齿(dir=1→UD=0)
  1  | dir_qn (U25 P6)   | 三角(折返)
```

> U32 门4 原来 做 ~rst_n 给 CD4027, 现在改 112 后 rst_n 直连 CLR, **U32 门4 空出备用**.

### U32 — 74HC00 (uni_ud 2选1 mux, 用 3 门)

> HC00 DIP-14: 门1=P1(A)/P2(B)/P3(Y) 门2=P4(A)/P5(B)/P6(Y) 门3=P9(A)/P10(B)/P8(Y) 门4=P12(A)/P13(B)/P11(Y). P14=VCC P7=GND.
> 功能: `uni_ud = fold ? dir_qn : ~dir` (NAND mux).

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 (A1) | ← fold (R5.Q2, reg5 bit2) | 门1 输入 A |
| 2 (B1) | ← dir_qn (U25.P6, HC112 Q1_n) | 门1 输入 B |
| 3 (Y1) | NAND1 = ~(fold·dir_qn) | → P9 (门3 A 输入) |
| 4 (A2) | ← ~fold (U23.P11, 门4 Y4) | 门2 输入 A |
| 5 (B2) | ← ~dir (U23.P8, 门3 Y3) | 门2 输入 B |
| 6 (Y2) | NAND2 = ~(~fold·~dir) | → P10 (门3 B 输入) |
| 7 (GND) | → GND | |
| 8 (Y3) | **→ uni_ud** | → U24.P10 (CD4029 UD) |
| 9 (A3) | ← NAND1 (U32.P3) | 门3 输入 A |
| 10 (B3) | ← NAND2 (U32.P6) | 门3 输入 B |
| 11 (Y4) | 悬空 | 门4 备用 |
| 12 (A4) | → GND | 门4 防悬空 |
| 13 (B4) | → GND | 门4 防悬空 |
| 14 (VCC) | → +5V | |

### U26 — 74HC283 (4-bit 加法器, 做比较器用)

> HC85 (4-bit 比较器) 不在库存, 用 74HC283 (4位加法器) 做 duty-counter 减法看进位.
> 引脚据 TI DM74LS283 datasheet (DIP-16):
> A1-A4=P5,3,14,12 / B1-B4=P6,2,15,11 / C0=P7 / C4=P9 / Σ1-Σ4=P4,1,13,10 / VCC=16,GND=8.

**减法原理**: `duty - counter = duty + (~counter + 1)`. 设 C0=1 (加1), B=~counter.
- C4(进位输出)=1 → duty ≥ counter (无借位, 结果非负)
- C4=0 → duty < counter (借位)

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 (Σ2) | 悬空 | 和输出 bit2 不用 |
| 2 (B2) | ← **~counter[1] (U33 门3, Y3=P6)** | B = ~counter (减数反码) bit1 |
| 3 (A2) | ← **duty[1] (R5.Q1, P5)** | A = duty bit1 (被减数) |
| 4 (Σ1) | 悬空 | 和输出 bit1 不用 |
| 5 (A1) | ← **duty[0] (R5.Q0, P2)** | A = duty bit0 (被减数, LSB) |
| 6 (B1) | ← **~counter[0] (U33 门2, Y2=P4)** | B = ~counter bit0 (LSB) |
| 7 (C0) | → **+5V** | 进位输入=1 (补码加法的+1) |
| 8 (GND) | → GND | |
| 9 (C4) | **→ U28 HC157 B1-4 (比较输出, 广播4位)** | C4=1 表示 duty≥counter → 高 (占空比/阈值调制) |
| 10 (Σ4) | 悬空 | 和输出 bit4(MSB) 不用 |
| 11 (B4) | ← **~counter[3] (U33 门5, Y5=P10)** | B = ~counter bit3 (MSB) |
| 12 (A4) | ← **duty[3] (R5.Q3, P9)** | A = duty bit3 (被减数, MSB) |
| 13 (Σ3) | 悬空 | 和输出 bit3 不用 |
| 14 (A3) | ← **duty[2] (R5.Q2, P6)** | A = duty bit2 |
| 15 (B3) | ← **~counter[2] (U33 门4, Y4=P8)** | B = ~counter bit2 |
| 16 (VCC) | → +5V | |

> ⚠️ **B 输入要 ~counter (反码), 不是 counter**! counter 来自 U29 HC273 的 Q0-3,
> 要先反相再接 283 的 B 输入. 反相用 U32 门4 (原来给 CD4027 的 ~rst_n, 现在 112 直连 rst_n 空出来了).
> 但 U32 门4 只有 1 路, counter 是 4 位, 要 4 个反相器 → 要 1 片 HC04 (U33 已有, 用剩余门).
>
> **输出逻辑**: HC85 输出 `counter<duty` (严格小于), 283 输出 `duty>=counter` (大于等于).
> 差一个步 (counter==duty 时 HC85=L, 283=H). 对占空比听感影响极小 (1/16 步).
> RTL 仍用 `<` 比较 (行为级等效), 上板用 283 的 C4.

### U27 — 74HC08 (4-bit AND, 位掩码调制)

> HC08 DIP-14: 门1=P1(A)/P2(B)/P3(Y) 门2=P4(A)/P5(B)/P6(Y) 门3=P9(A)/P10(B)/P8(Y) 门4=P12(A)/P13(B)/P11(Y). P14=VCC P7=GND.

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 (A1) | ← U29.Q0 (P2, counter bit0) | 门1 输入 A |
| 2 (B1) | ← R5.Q0 (P2, duty bit0) | 门1 输入 B |
| 3 (Y1) | → U28.P2 (HC157 A1, AND bit0) | counter AND duty bit0 |
| 4 (A2) | ← U29.Q1 (P5, counter bit1) | 门2 输入 A |
| 5 (B2) | ← R5.Q1 (P5, duty bit1) | 门2 输入 B |
| 6 (Y2) | → U28.P5 (HC157 A2, AND bit1) | AND bit1 |
| 7 (GND) | → GND | |
| 8 (Y3) | → U28.P13 (HC157 A3, AND bit2) | AND bit2 |
| 9 (A3) | ← U29.Q2 (P6, counter bit2) | 门3 输入 A |
| 10 (B3) | ← R5.Q2 (P6, duty bit2) | 门3 输入 B |
| 11 (Y4) | → U28.P10 (HC157 A4, AND bit3) | AND bit3 |
| 12 (A4) | ← U29.Q3 (P9, counter bit3) | 门4 输入 A |
| 13 (B4) | ← R5.Q3 (P9, duty bit3) | 门4 输入 B |
| 14 (VCC) | → +5V | |

> counter AND duty4 → 保留 duty4=1 的位, 屏蔽=0 的位 → 降精度加量化高频.
> duty4=15(1111) 时 AND=原始 counter, duty4=0 时静音.

### U28 — 74HC157 (四 2选1, mode_sel 选 AND/比较)

> HC157 DIP-16 引脚 (据 hc157.v 模型, TI 74HC157 datasheet):
> P1=Select(S) P2=A1 P3=B1 P4=Y1 P5=A2 P6=B2 P7=Y2 P8=GND
> P9=Y3 P10=A4 P11=B4 P12=Y4 P13=A3 P14=B3 P15=/Enable(低有效) P16=VCC
> 功能: /Enable=0 时, Select=0 → Y=A, Select=1 → Y=B. 4 路独立 2选1, 共享 S 和 /E.
>
> ⚠️ **为何不用 HC153**: HC153 是双 4选1 (2 位地址选 4 路之 1), 只有 1Y/2Y 两个输出.
> 波形通道需要 4 个独立 2选1 (mode_sel 在 AND 结果和比较结果间选, 每位独立),
> 必须用 HC157 (四 2选1, 4 个 Y 输出). 之前接线表错用 HC153 是选型错误.

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 (Select) | ← **mode_sel (R5.Q4, P12)** | 0=选AND(A), 1=选比较(B) |
| 2 (A1) | ← **U27.P3 (Y1, AND 输出 bit0)** | AND bit0 |
| 3 (B1) | ← **U26.P9 (C4, 比较输出)** | 比较 bit0 (C4 广播 4 位) |
| 4 (Y1) | → **U30.P7 (DB4, DAC bit0)** | 输出 bit0 (LSB) |
| 5 (A2) | ← **U27.P6 (Y2, AND 输出 bit1)** | AND bit1 |
| 6 (B2) | ← **U26.P9 (C4, 比较输出)** | 比较 bit1 |
| 7 (Y2) | → **U30.P6 (DB5, DAC bit1)** | 输出 bit1 |
| 8 (GND) | → GND | |
| 9 (Y3) | → **U30.P5 (DB6, DAC bit2)** | 输出 bit2 |
| 10 (A4) | ← **U27.P11 (Y4, AND 输出 bit3)** | AND bit3 (MSB) |
| 11 (B4) | ← **U26.P9 (C4, 比较输出)** | 比较 bit3 |
| 12 (Y4) | → **U30.P4 (DB7, DAC bit3)** | 输出 bit3 (MSB) |
| 13 (A3) | ← **U27.P8 (Y3, AND 输出 bit2)** | AND bit2 |
| 14 (B3) | ← **U26.P9 (C4, 比较输出)** | 比较 bit2 |
| 15 (/Enable) | → GND | 常开 (输出始终有效) |
| 16 (VCC) | → +5V | |

> mode_sel=0(Select=0) → Y=A(AND): counter AND duty4, 位掩码调制 (duty=15 时=原始波形)
> mode_sel=1(Select=1) → Y=B(比较): C4 广播 4 位全同 (锯齿+比较=方波, 三角+比较=削顶谐波)
> RTL 等效: `uni_sel = uni_mode ? uni_cmp_out : uni_and_out` (hc157.v 行为级)
> HC157 的 4 个 B 输入全接 U26.P9(C4) 同一根线 (比较结果广播).

### U29 — 74HC273 (毛刺滤除, 4-bit)

**据 TI 74HC273 datasheet**: 八 D 触发器带异步清零, DIP-20. 本项目只用低 4 位.
CD4029 的 Q 输出在计数瞬间有毛刺 (各位不同步跳变), HC273 在 clk 下降沿采样稳定值.

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 (/MR) | ← rst_n | 异步清零 |
| 11 (CP) | ← **~clk (U33 HC04 门1)** | clk 下降沿采样 (CD4029 上升沿后, 取稳定值) |
| 3 (D0) | ← U24.P6 (Q1, LSB) | CD4029 Q1 → D0 |
| 4 (D1) | ← U24.P11 (Q2) | CD4029 Q2 → D1 |
| 7 (D2) | ← U24.P14 (Q3) | CD4029 Q3 → D2 |
| 8 (D3) | ← U24.P2 (Q4, MSB) | CD4029 Q4 → D3 |
| 2 (Q0) | → U33 HC04 门2 (→ U26 B1) + U27 HC08 | 干净波形 bit0 |
| 5 (Q1) | → U33 HC04 门3 (→ U26 B2) + U27 HC08 | 干净波形 bit1 |
| 6 (Q2) | → U33 HC04 门4 (→ U26 B3) + U27 HC08 | 干净波形 bit2 |
| 9 (Q3) | → U33 HC04 门5 (→ U26 B4) + U27 HC08 | 干净波形 bit3 |

> ⚠️ 只用 4 位, HC273 高 4 位 (D4-7) 接 GND 不用 (或用 HC174 六 D 触发器替代, 更省).
> Gigatron 同款解法: 计数器输出过边沿寄存器滤毛刺再进 DAC.

### U30 — TLC7524 #1 (波形生成)

**TLC7524 引脚 (实测 DIP-16, 据 CLAUDE.md 已核对)**:
Pin1=OUT1 / Pin2=OUT2 / Pin3=GND / Pin4-7=DB7-DB4 / Pin8=DB3 / Pin9-11=DB2-DB0 /
Pin12=CS(→GND) / Pin13=WR(→GND) / Pin14=VDD(+5V) / Pin15=REF / Pin16=RFB.

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 (OUT1) | → **U31.P15 (REF)** | 波形模拟量 (给音量 DAC 当 REF) |
| 2 (OUT2) | → GND | |
| 3 (GND) | → GND | |
| 4 (DB7) | ← U28.P12 (HC157 Y4, 波形 bit3 MSB) | 4-bit 波形 MSB |
| 5 (DB6) | ← U28.P9 (HC157 Y3, 波形 bit2) | |
| 6 (DB5) | ← U28.P7 (HC157 Y2, 波形 bit1) | |
| 7 (DB4) | ← U28.P4 (HC157 Y1, 波形 bit0 LSB) | |
| 8 (DB3) | → GND | 低 4 位接地 (4-bit 精度) |
| 9 (DB2) | → GND | |
| 10 (DB1) | → GND | |
| 11 (DB0) | → GND | |
| 12 (CS) | → GND | 常选通 |
| 13 (WR) | → GND | 透明模式 (常写入) |
| 14 (VDD) | → +5V | |
| 15 (REF) | → +5V | 满量程基准 |
| 16 (RFB) | → GND | |

### U31 — TLC7524 #2 (音量衰减)

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 (OUT1) | → **耦合电容 → 运放 → 喇叭** | 最终输出 (输出链路铁律, CLAUDE.md) |
| 2 (OUT2) | → GND | |
| 3 (GND) | → GND | |
| 4 (DB7) | ← R4.Q3 (P9, vol[3] MSB) | 4-bit 音量 |
| 5 (DB6) | ← R4.Q2 (P6, vol[2]) | |
| 6 (DB5) | ← R4.Q1 (P5, vol[1]) | |
| 7 (DB4) | ← R4.Q0 (P2, vol[0] LSB) | |
| 8 (DB3) | → GND | 低 4 位接地 |
| 9 (DB2) | → GND | |
| 10 (DB1) | → GND | |
| 11 (DB0) | → GND | |
| 12 (CS) | → GND | 常选通 |
| 13 (WR) | → GND | 透明模式 |
| 14 (VDD) | → +5V | |
| 15 (REF) | ← **U30.P1 (OUT1)** | 被衰减波形 (级联输入) |
| 16 (RFB) | → GND | |

> 级联乘法衰减: OUT1_总 = 波形 × (vol/16). vol=0 静音, vol=15 满幅.
> RTL 等效: `uni_atten = uni_wave_db * {uni_vol, 4'b0000}; uni_audio = atten[15:8]`.

### U33 — 74HC04 (clk 反相 + counter 反相, 波形通道自包含)

> HC04 DIP-14: 门1=P1(A)/P2(Y) 门2=P3(A)/P4(Y) 门3=P5(A)/P6(Y) 门4=P9(A)/P8(Y) 门5=P11(A)/P10(Y) 门6=P13(A)/P12(Y). P14=VCC P7=GND.

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 (A1) | ← clk (4MHz) | 门1 输入 |
| 2 (Y1) | **→ ~clk** | → U29.P11 (HC273 CP) |
| 3 (A2) | ← counter[0] (U29.Q0, P2) | 门2 输入 |
| 4 (Y2) | **→ ~counter[0]** | → U26.P6 (HC283 B1) |
| 5 (A3) | ← counter[1] (U29.Q5) | 门3 输入 |
| 6 (Y3) | **→ ~counter[1]** | → U26.P2 (HC283 B2) |
| 7 (GND) | → GND | |
| 8 (Y4) | **→ ~counter[2]** | → U26.P15 (HC283 B3) |
| 9 (A4) | ← counter[2] (U29.Q6) | 门4 输入 |
| 10 (Y5) | **→ ~counter[3]** | → U26.P11 (HC283 B4) |
| 11 (A5) | ← counter[3] (U29.Q9) | 门5 输入 |
| 12 (Y6) | 悬空 | 门6 备用 |
| 13 (A6) | → GND | 门6 防悬空 |
| 14 (VCC) | → +5V | |

> HC273 要 ~clk (上升沿锁存, 接 ~clk 在 clk 下降沿采样稳定值).
> HC112 直连 clk (下降沿触发, 不需反相).
> **283 要 ~counter (4位反码)** 做 duty-counter 减法: B=~counter, C0=1.
> HC04 共 6 门: ~clk(1) + ~counter(4) = 5 门, 剩门6 备用.

---

## 五、电源

| 芯片 | VDD | GND |
|------|-----|-----|
| HC161 (U20-22) | P16 | P8 |
| HC00 (U23, U32) | P14 | P7 |
| CD4029 (U24) | P16 | P8 |
| HC112 (U25) | P16 | P8 |
| HC283 (U26) | P16 | P8 |
| HC08 (U27) | P14 | P7 |
| HC157 (U28) | P16 | P8 |
| HC273 (U29) | P20 | P10 |
| TLC7524 (U30, U31) | P14 | P3 |
| HC04 (U33) | P14 | P7 |

> 每片 VDD 就近加 0.1μF 去耦. 所有 GND 共地.
> 波形通道共 14 片: 3×HC161 + 2×HC00(U23/U32) + CD4029 + HC112 + HC283 + HC08 + HC157 + HC273 + 2×TLC7524 + HC04(U33).
