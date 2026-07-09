# PSG3 v0.5 交接文档

> PSG3 v0.5 = v0.4 (方波 + 噪音) **全部保留** + **新增波形通道** (方波/三角/锯齿/反锯齿切换)
> 交接时间：2026-07-09
> 状态：**三通道 RTL + tb 0 错误，C仿真器通过，4MHz 架构，待上板验证**

## 一句话现状

v0.4 的方波通道 + 噪音通道**原样保留**（reg0/1/2, clk=sq_clk 预分频 64kHz）。
v0.5 **新增波形通道**（reg3/4/5, clk=4MHz 直连）——一个 CD4029 4-bit 计数器，wave_sel 切换 4 种波形，HC283 比较器 + HC08 AND 门双路径，mode_sel 1-bit 切换音色调制方式。
**三通道并存**，各自独立 TLC7524 输出，上板分别接喇叭对比音色。

**周期分两类**（核心：wave_sel[0]=fold 控制有无 HC112 折返）：
- 锯齿族（锯齿/方波/反锯齿, fold=0）：单向回绕 = **16步/周期**, `freq = 4MHz/(16×(4096-p12))`
- 三角（fold=1）：HC112 折返 0→15→0 = **30步/周期**, `freq = 4MHz/(30×(4096-p12))`
- 两套 period 查找表：`host/uni_period_table.h` (uni_period12_saw / uni_period12_tri)

---

## ⚠️ 版本隔离原则

**v0.4 是已定案版本（已上板验证），v0.5 不改 v0.4 任何文件。**
- v0.4 的 RTL / docs / host 驱动全部保持原样（在 `PSG3 v0.4/` 目录）
- v0.5 是独立文件夹，把 v0.4 的方波 + 噪音**原样合入** v0.5 顶层 + 新增波形通道
- 寄存器分配: reg0/1=方波, reg2=噪音, **reg3/4/5=波形**（新增, 避开 v0.4 占用的地址）

---

## 波形通道原理（核心创新）

**一个 CD4029 4-bit 计数器**，wave_sel 切换 4 种波形。核心区别在**有无 HC112 折返**（wave_sel[0]=fold）：

```
3×HC161 (period12) → freq_tc → CD4029 (4-bit 波形计数器)
                                   │ Q0-3
                    ┌──────────────┴──────────────────┐
                    │ HC273 (滤毛刺)                  │
                    │    ┌──────────┬─────────────────┤
                    │    │ HC283比较 │ HC08 AND        │
                    │    │ Q<duty   │ Q&duty          │
                    │    └────┬─────┴────┬────────────┘
                    └─ HC153 选 ─────────┘
                              │ wave_sel + mode_sel
                    TLC7524#1 (波形) → TLC7524#2 (音量) → 喇叭
```

| wave_sel | 波形 | fold | dir | CD4029 行为 | 周期 | HC153 选 | duty4 作用 |
|----------|------|------|-----|------------|------|---------|-----------|
| 00 | 锯齿 | 0 | 0 | 单向加 0→15→0 | **16步** | mode_sel 选 | 比较阈值/AND掩码 |
| 01 | 三角 | 1 | - | HC112 折返 0→15→0 | **30步** | mode_sel 选 | 比较阈值/AND掩码 |
| 10 | 方波 | 0 | 0 | 单向加 0→15→0 | **16步** | **固定比较** | **占空比** |
| 11 | 反锯齿 | 0 | 1 | 单向减 15→0→15 | **16步** | mode_sel 选 | 比较阈值/AND掩码 |

**wave_sel 两 bit 拆解**：bit[1]=dir（0加/1减），bit[0]=fold（0单向16步/1折返30步）。
方波 = 锯齿底子（fold=0+dir=0）+ 强制走 HC283 比较（mode_sel 无效）。
**mode_sel 1-bit 切换音色调制**：1=HC283比较（阈值调制，三角→方波加奇次谐波），0=HC08 AND（位掩码，降精度加量化高频）。同一个 duty4，两种模式产生不同音色。

> **关于占空比的历史教训**：v0.3 的占空比靠 toggle 后分频链，25%/12.5% 会**降八度**。
> v0.5 用 HC283 比较器，占空比完全独立于频率（不降八度）。

> **关于周期的认知（2026-07-09 修正）**：之前误以为"所有波形统一 30 步"。
> 实际锯齿族（无折返）是 16 步/周期，三角（有折返）是 30 步/周期。所以分两套 period 表。
> 这符合"提 clk 或降步数才能提高精度墙"——16步墙高（低音下不去到 B1），30步墙低（高音 G7 突破 1%）。

---

## 寄存器 (三通道并存, 独热码地址)

```
reg0 (0x01): 方波 period (8 bit)                    ← v0.4 方波通道
reg1 (0x02): 方波控制 vol/duty/mode/ref             ← v0.4 方波通道
reg2 (0x04): 噪音控制 vol/freq/bind
reg3 (0x08): 波形 period12[7:0]                     ← v0.5 波形通道
reg4 (0x10): 波形 period12[11:8] | vol[3:0]         ← v0.5 波形通道
reg5 (0x20): 波形 duty[3:0](bit0-3) | mode_sel(bit4) | wave_sel[1:0](bit5-6) | 预留(bit7)
              wave_sel[1]=dir (0加=锯齿/方波, 1减=反锯齿)
              wave_sel[0]=fold (0单向16步, 1折返30步=三角)
              方波 = dir=0 + fold=0 + 强制比较 (mode_sel 无效)
              mode_sel: 1=HC283比较(阈值调制) 0=HC08 AND(位掩码)
```

频率和音量放 reg0+reg1（最重要的两个参数在一起）。

### 音高公式（两套，按波形周期）

```
锯齿族 (16步): freq = 4000000 / (16 × (4096 - period12))
              覆盖: B1(61Hz) ~ C8(4186Hz), B1~C8 <0.55%, 74/85音<1%
三角 (30步):  freq = 4000000 / (30 × (4096 - period12))
              覆盖: C1(32.7Hz) ~ C8(4186Hz), 84/85音<1% (G7=1.12%最差)
查找表: host/uni_period_table.h (uni_period12_saw / uni_period12_tri, 穷举优化)
```

> **为什么两套**：锯齿族 16 步墙高（4MHz/16=250kHz），低音下不去（B1 以下失效）；
> 三角 30 步墙低（4MHz/30=133kHz），低音能到 C1 但高音精度差。各取所长。

### 关于精度的认知（重要）

STC32G 的 AY8910/SN76489 仿真器精度好，是用了 **NCO（24-bit 相位累加）**，不是计数器 reload。
真 AY8910 芯片在 1.79MHz 下高音精度也差（12-bit 直接计数）。本项目走真硬件路线（74 计数器），
用 4MHz 高 clk 缓解，非 NCO。NCO 留给后续 SCC。

---

## 芯片清单

### 总线层 (13 片, v0.4 不变)
2×LS373(电平转换) + HC374(地址锁存) + 8×HC374(reg0-7 寄存器) + HC04(NOT) + 3×HC08(选通)
> 详见 wiring-table-bus.md. 物理接线不变, 只改 U5/U6/U7 (reg3/4/5) 的 Q 去向给波形通道.

### 方波通道 CH0 (8 片, v0.4 不变)
2×HC161(period 8-bit) + HC00(PE反相) + HCT74(toggle) + HC153(占空比选通) + HC08(占空比AND) + TLC7524
> clk=sq_clk (预分频 64kHz). reg0/1 控制. 详见 wiring-table-square.md (复制 v0.4).

### 波形通道 CH2 (14 片, v0.5 新)
3×HC161(period12) + 2×HC00(U23反相器组/U32 UD-mux) + CD4029(波形) + HC112(方向) +
HC283(比较) + HC08(AND) + HC153(选择) + HC273(滤毛刺) + 2×TLC7524(波形+音量级联) + HC04(clk反相)

> U23 HC00 (4门全用): ~freq_tc(PE) / ~CO(at_extreme) / ~dir / ~fold
> U32 HC00 (4门全用): uni_ud 2选1 mux (3门) + ~rst_n (门4)
> at_extreme = ~CO (CD4029 CO 真值表已含 CI 条件, freq_tc 冗余, 省 1 个 AND 门)
> clk=4MHz 直连. reg3/4/5 控制. 详见 wiring-table-uni.md.

### 预分频 (3 片, 方波+噪音用)
2×HC161(÷63, reload=193/0xC1) + HC00(PE反相). 4MHz÷63=63492Hz(-0.8%, 软件补偿)
> 详见 wiring-table-prescaler.md. sq_clk 给方波通道 + 噪音通道.

### 噪音通道 CH1 (7 片 + 2 电容, v0.4 不变)
CD4070 + HC374 + HC161 + HC153 + TLC7524 + HC00×2
> clk=sq_clk. reg2 控制. 详见 wiring-table-noise.md.

**合计: 45 片** (总线13 + 方波8 + 波形14 + 预分频3 + 噪音7)
> 三通道各自独立 TLC7524 输出, 上板分别接喇叭对比音色.

---

## C 仿真器 + WAV

**`host/uni_sim.c`** (gcc 编译, 详见 compile-sim-guide.md "C 编译器" 节):
- `./uni_sim` — 精度表 (双套: 锯齿族16步 B1~C8 + 三角30步 C1~C8)
- `./uni_sim table` — 双 period12 查找表 → `uni_period_table.h` (saw/tri 各一张)
- `./uni_sim wav` — 4 波形 85 音扫频 (C1→C8, 各波形按对应周期步数算)
- `./uni_sim duty` — C6 音高, 16 档 duty 扫频 (3 波形)
- `./uni_sim vol` — C5 音高, 音量衰减对比 (已废弃 AND 方案, 保留级联)

编译运行:
```bash
PATH="/d/msys64/mingw64/bin:$PATH" gcc -O2 -std=c99 uni_sim.c -o uni_sim.exe -lm
PATH="/d/msys64/mingw64/bin:$PATH" ./uni_sim.exe
```

**WAV 试听** (`tb/`):
- `saw_sweep.wav` / `tri_sweep.wav` / `sq_sweep.wav` / `rsaw_sweep.wav` — 4 波形扫频
- `duty_sq.wav` / `duty_tri.wav` / `duty_saw.wav` — C6 duty 扫频 (16 档)

---

## 关键文件

```
PSG3 v0.5/
├── docs/
│   ├── handoff.md                  # 本文件
│   ├── wiring-table-bus.md         # ⭐ 接口层 YM2413 总线 (U0-U13, 复制v0.4改Q去向)
│   ├── wiring-table-prescaler.md   # ÷63 预分频 (方波/噪音用 64kHz)
│   ├── wiring-table-uni.md         # ⭐ 波形通道 (U20-U32 逐脚, 13 片, reg3/4/5)
│   └── wiring-table-noise.md       # 噪音 (照抄 v0.4, reg2, clk 改 sq_clk)
├── rtl/psg3_top.v                  # 顶层 (方波 + 波形 + 噪音 三通道 + 预分频)
├── host/
│   ├── uni_sim.c                   # ⭐ C 仿真器 (双周期 saw16步/tri30步)
│   └── uni_period_table.h          # 双 period12 查找表 (saw/tri)
└── tb/
    ├── psg3_uni_tb.v               # ⭐ 三通道验证 (0 错误, 8 项全 PASS)
    ├── cd4029_tb.v                 # CD4029 模型验证
    ├── cd4029_tri_tb.v             # 折返逻辑验证
    ├── saw_sweep.wav               # 锯齿扫频
    ├── tri_sweep.wav               # 三角扫频
    ├── sq_sweep.wav                # 方波扫频
    ├── rsaw_sweep.wav              # 反锯齿扫频
    ├── duty_sq.wav                 # 方波 C6 duty 扫频
    ├── duty_tri.wav                # 三角 C6 duty 扫频
    └── duty_saw.wav                # 锯齿 C6 duty 扫频
```

项目级共享 RTL 原语（仓库根 `rtl/`，v0.5 新建）：
- `rtl/cd4029.v` — CD4029 4-bit 可逆计数器（据 ST/TI/Fairchild datasheet）
- `rtl/hc112.v` — 74HC112 双 JK 下降沿触发器（据 TI SN74HC112 datasheet）

> ⚠️ **选片先查 `docs/inventory.md`（库存表）**，表里没有的不能用。
> HC85/CD4027 不在库存, 已用 HC283(加法器做比较) + HC112(JK触发器) 替代, 详见接线表.

---

## 待上板验证（仿真盲区）

1. **CD4029 + HC112 在 4MHz 下稳定性** (CD4029 CMOS fmax 够, 但面包板寄生)
2. **HC283 比较器输出 (C4进位) 毛刺** (HC273 滤 counter 后, 283 在后面可能毛刺)
3. **HC112 下降沿触发 vs CD4029 上升沿计数 的时序配合** (采样窗口)
4. **HC08 AND 门输出毛刺** (HC273 后)
5. **HC153 波形切换瞬时噪声**
6. **TLC7524 级联 REF 阻抗** (#1 OUT 能否直驱 #2 REF)
7. **wave_sel / mode_sel 切换时平滑度**
8. **CD4029 CO 尖刺** (datasheet 警告, 仿真理想看不到)
9. **12-bit period 频率精度实测** (锯齿族16步 B1~C8 <0.55%, 三角30步 C1~C8 <1%, G7 最差 1.12%)
10. **HC283 的 duty>=counter vs HC85 的 duty>counter 差一步** (1/16步, 听感影响待验证)

---

## 沟通纪律（下个窗口必读 CLAUDE.md）

- **v0.4 是定案版本，扩展工作新建文件夹，不改旧版文件**
- **地址分配以驱动 py（硬件验证）为准**，不看 RTL 注释
- **有效音域 = A0~C8 (27.5~4186Hz)**，全音域都要保证精度
- **period 精度墙 = clk/步数**，提 clk 或降步数才能提高
- **周期分两类**：锯齿族单向 16 步 / 三角折返 30 步，分两套 period 表（不是统一 30 步！）
- **wave_sel 两 bit = dir + fold**：bit[1]=dir(加/减)，bit[0]=fold(单向/折返)，方波=锯齿+强制比较
- **占空比不能降八度**（v0.5 HC283 比较器解决）
- **数字音量必须用乘法（TLC7524 级联），AND 门破坏波形音色不可用**
- **CD4029/HC112 引脚必查 datasheet**（已在 rtl/ 注释标来源）
- **C 编译器用 MSYS2 gcc** (`D:\msys64\mingw64\bin\gcc.exe`，PATH 要含 mingw64/bin)
