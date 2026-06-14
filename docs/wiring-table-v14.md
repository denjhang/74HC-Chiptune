# WT3 WSG v1.4 接线表 — 4 通道 16-bit 相位 TDM(30 IC,0 隐藏门)

**生成日期**: 2026-06-15
**版本**: v1.4(16-bit phase_acc + 154 译码 + 4 通道 TDM + 钢琴包络级联)
**核对来源**: [rtl/wt3_core.v](../rtl/wt3_core.v) + [rtl/wt3_spfm_bus.v](../rtl/wt3_spfm_bus.v)
**验证**: 4 通道 C-E-G-C5 0.2s 级联 + 钢琴包络 PASS(听感确认)
**全部 74HC 显式实例化**:
- 反相器:2 片 74HC04(无 `assign ~`)
- 与门:1 片 74HC08(`tc_lo & RST_n`)
- 或门:1 片 74HC32(`decode_disable`)
- 声卡内部 0 隐藏门(grep `~ & | ^` 在 wt3_core.v 中 0 个可执行匹配)

---

## 芯片清单(30 IC)

| # | 位号 | 型号 | 封装 | 功能 | 实例名 | 文件 |
|---|------|------|------|------|--------|------|
| 1 | U1 | 74HC373 | DIP-20 | SPFM D[7:0] 透明锁存 | u_d_latch | spfm_bus.v |
| 2 | U2 | 74HC174 | DIP-16 | 同步器(addr/data wr_pulse) | u_sync | spfm_bus.v |
| 3 | U3 | 74HC377 | DIP-20 | SPFM 地址寄存器 | u_addr_reg | spfm_bus.v |
| 4 | U4 | 74HC04 | DIP-14 | 反相器 #1(174 Q3/Q5 → 低有效 wr_pulse) | u_inv_spfm | spfm_bus.v |
| 5 | U5 | 74HC377 | DIP-20 | reg_a_lo(phase_acc 低字节) | u_reg_a_lo | core.v |
| 6 | U6 | 74HC377 | DIP-20 | reg_a_hi(phase_acc 高字节) | u_reg_a_hi | core.v |
| 7 | U7 | 74HC377 | DIP-20 | reg_b_lo(phase_step 低字节) | u_reg_b_lo | core.v |
| 8 | U8 | 74HC377 | DIP-20 | reg_b_hi(phase_step 高字节) | u_reg_b_hi | core.v |
| 9 | U9 | 74HC377 | DIP-20 | reg_c(volume) | u_reg_c | core.v |
| 10 | U10 | 74HC161 | DIP-16 | step_lo(step[3:0]) | u_step_lo | core.v |
| 11 | U11 | 74HC161 | DIP-16 | step_hi(step[5:4]) | u_step_hi | core.v |
| 12 | U12 | 74HC08 | DIP-14 | 与门:AND(tc_lo, RST_n) → U11.CEP | u_and | core.v |
| 13 | U13 | 39SF040 | DIP-32 | 微码 ROM(64 字节 × 4 通道) | u_mc | core.v |
| 14 | U14 | 39SF040 | DIP-32 | wavetable ROM(8KB) | u_wave | core.v |
| 15 | U15 | 74HC154 | DIP-24 | 4-16 译码(step[3:0] → latch/dac_clk) | u_decode | core.v |
| 16 | U16 | 74HC04 | DIP-14 | 反相器 #2(154 Y13 → 273 CP, + RST_n/CS_n → hc32) | u_inv | core.v |
| 17 | U17 | 74HC32 | DIP-14 | 或门:OR(~RST_n, ~CS_n) → 154 G_n | u_or | core.v |
| 18 | U18 | 74HC157 | DIP-16 | RAM 地址 mux 低 4 位 | u_addr_lo | core.v |
| 19 | U19 | 74HC157 | DIP-16 | RAM 地址 mux 高 4 位 | u_addr_hi | core.v |
| 20 | U20 | 74HC157 | DIP-16 | RAM DI mux 低 4 位 | u_di_lo | core.v |
| 21 | U21 | 74HC157 | DIP-16 | RAM DI mux 高 4 位 | u_di_hi | core.v |
| 22 | U22 | 74HC157 | DIP-16 | RAM WE/OE 选择 | u_we_oe_mux | core.v |
| 23 | U23 | 74HC157 | DIP-16 | writeback DI lo mux | u_wb_mux | core.v |
| 24 | U24 | 74HC157 | DIP-16 | writeback DI hi mux | u_wb_mux_hi | core.v |
| 25 | U25 | CY62256 | DIP-28 | 参数 RAM(32KB, 用 32B) | u_ram | core.v |
| 26 | U26 | 74HC283 | DIP-16 | 加法器 #1(位 0-3) | u_adder_0 | core.v |
| 27 | U27 | 74HC283 | DIP-16 | 加法器 #2(位 4-7) | u_adder_1 | core.v |
| 28 | U28 | 74HC283 | DIP-16 | 加法器 #3(位 8-11) | u_adder_2 | core.v |
| 29 | U29 | 74HC283 | DIP-16 | 加法器 #4(位 12-15) | u_adder_3 | core.v |
| 30 | U30 | 74HC273 | DIP-20 | DAC 输出锁存(TDM 4 通道共享) | u_dac | core.v |

**外部元件(不计入 IC 数)**:
- Y1: 3.072MHz 晶振(HC-49S 或 3225 SMD)
- DAC: 8-bit R-2R 电阻网络(20kΩ/10kΩ 0.1%)
- 低通滤波: RC 一阶(截止 ~20-24 kHz,滤掉 48kHz 镜像)→ LM386 音频放大器
- C1-C30: 每片 IC 的 0.1μF 去耦

**相比 v1.3(+11 IC)**:
- +2× 377(reg_a_hi, reg_b_hi):16-bit 相位需要高低字节两个寄存器
- +2× 283(adder #3, #4):16-bit 加法需要 4 片级联
- +1× 154(step[3:0] → latch/dac_clk 硬译码)
- +1× 157(writeback lo/hi mux)
- +2× 04(显式反相器,替代 `assign ~`)
- +1× 08(显式与门,替代 `tc_lo & RST_n`)
- +1× 32(显式或门,替代 `~RST_n | ~CS_n`)
- +1× 377(SPFM 地址寄存器 u_addr_reg,之前在 spfm_bus 内的隐式计数漏算)
- **声卡内部 0 隐藏门**(全部 `assign` 只剩总线切片/拼接)

---

## 全局网络

| 网络 | 说明 | 源 |
|------|------|------|
| VCC | +5V | 电源 |
| GND | 地 | 电源 |
| STEP_CLK | 3.072MHz 主时钟(48kHz × 64 step) | Y1 晶振 |
| SPFM_CLK | 10MHz(SPFM 总线时钟) | 外部 CPU |
| SPFM_RST_n | 复位(低有效) | 外部 CPU |
| SPFM_D[7:0] | SPFM 数据总线 | 外部 CPU |
| SPFM_A0 | 地址/数据选择 | 外部 CPU |
| SPFM_CS_n | 片选(低有效) | 外部 CPU |
| SPFM_WR_n | 写使能(低有效) | 外部 CPU |
| SPFM_RD_n | 读使能(低有效) | 外部 CPU(本设计未用) |

---

## 外部协议译码(PCB 飞线,不算声卡内部门)

按 [Hidden Gates Boundary 规则](../),SPFM 总线进入 373 入口前的协议译码不算隐藏门:

| 信号 | 表达式 | 用途 |
|------|--------|------|
| le | ~(CS_n \| WR_n) | 373 LE |
| write_active | ~CS_n & ~WR_n & RST_n | 主机写操作 |
| addr_wr_comb | write_active & ~A0 | 写地址相位 |
| data_wr_comb | write_active & A0 | 写数据相位 |

这 4 行位于 wt3_spfm_bus.v:53-56,**是 CPU 侧工作,不是声卡内部门**。

---

## 微码控制字(v1.4,8-bit)

```
bit 7: ram_oe_n       (0=read RAM)
bit 6: ram_we_n       (0=write RAM)
bit 5-3: reserved
bit 2-0: ram_sub_addr (3-bit, 0-7 子地址)
```

latch 信号由 **154 硬译码 step[3:0]** 产生。

---

## 154 硬译码 + 154 使能逻辑

### 译码表

| step[3:0] | 154 输出 | 用途 |
|-----------|---------|------|
| 1 (0001) | Y1 | latch_a_lo_n → U5 |
| 3 (0011) | Y3 | latch_a_hi_n → U6 |
| 5 (0101) | Y5 | latch_b_lo_n → U7 |
| 7 (0111) | Y7 | latch_b_hi_n → U8 |
| 9 (1001) | Y9 | latch_c_n → U9 |
| 13 (1101) | Y13 | dac_clk_n → 反相 → U30.CP |
| 其他 | 高(无效) | 无 |

### 154 使能 (decode_disable) 显式实现

```
decode_disable = ~SPFM_RST_n | ~SPFM_CS_n   (低有效 OR)
              = OR(NOT RST_n, NOT CS_n)
```

用 2 片 IC 实现(无 assign):
- **U16 (hc04)** 第 2/3 路:Y2 = ~RST_n,Y3 = ~CS_n
- **U17 (hc32)** 第 1 路:Y1 = OR(Y2_hc04, Y3_hc04) = decode_disable
- 输出送 U15 (hc154) 的 G_n

### hc161 step_hi CEP 显式实现

```
step_hi_cep = tc_lo & SPFM_RST_n   (与门, 复位时停计数, 正常时级联)
```

- **U12 (hc08)** 第 1 路:Y1 = AND(tc_lo, RST_n) = step_hi_cep
- 输出送 U11 (hc161) 的 CEP

---

## 每通道 16-step 微码(v1.4: 14 工作 + 2 NOP)

```
step 0:   读 acc_lo         OE=0, sub_addr=0
step 1:   latch_a_lo        [154 Y1]  U5 锁存
step 2:   读 acc_hi         OE=0, sub_addr=1
step 3:   latch_a_hi        [154 Y3]  U6 锁存
step 4:   读 step_lo        OE=0, sub_addr=2
step 5:   latch_b_lo        [154 Y5]  U7 锁存
step 6:   读 step_hi        OE=0, sub_addr=3
step 7:   latch_b_hi        [154 Y7]  U8 锁存
step 8:   读 volume         OE=0, sub_addr=4
step 9:   latch_c           [154 Y9]  U9 锁存
step 10:  写回 acc_lo       WE=0, sub_addr=0
step 11:  NOP (WE=1)        ↑ 关键:让 62256 WE_n 产生完整下降沿
step 12:  写回 acc_hi       WE=0, sub_addr=1
step 13:  dac_clk 锁存      [154 Y13] U30 上升沿锁存
step 14-15: NOP             SPFM 可在此写参数
```

详见 [wt3-architecture.md §5](wt3-architecture.md)。

---

## RAM 地址映射(v1.4: 每通道 8 字节)

5-bit RAM 地址 = `{step[5:4](通道号), mc_ram_sub_addr[2:0]}`

| RAM 地址 | 通道 | 字段 | 写入者 |
|---------|------|------|--------|
| 0x00-0x01 | ch0 | phase_acc_lo/hi | 微码自动写回 |
| 0x02-0x03 | ch0 | phase_step_lo/hi | CPU 写 |
| 0x04 | ch0 | volume | CPU 写 |
| 0x05-0x07 | ch0 | reserved | |
| 0x08-0x0F | ch1 | 同上 | |
| 0x10-0x17 | ch2 | 同上 | |
| 0x18-0x1F | ch3 | 同上 | |
| 0x20-0x7FFF | 未用 | | |

每通道 8 字节 × 4 通道 = 32 字节(62256 有 32KB,余量 1024 倍)。

---

## 关键芯片接线

### U4: 74HC04 #1(SPFM 同步链反相,spfm_bus.v)

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 | A1 | addr_q3(U2.Q3) |
| 2 | Y1 | addr_wr_pulse_n → U3./Enable |
| 3 | A2 | data_q2(U2.Q5) |
| 4 | Y2 | data_wr_pulse_n → U22.A1 |
| 5,6,9,8,11,10,13,12 | A3-A6/Y3-Y6 | GND(未用) |
| 7 | GND | GND |
| 14 | VDD | VCC |

### U12: 74HC08(与门,core.v)

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 | A1 | tc_lo(U10.TC) |
| 2 | B1 | SPFM_RST_n |
| 3 | Y1 | step_hi_cep → U11(hc161).CEP |
| 4-6, 9-12 | 其他 3 路 | GND(未用) |
| 7 | GND | GND |
| 14 | VDD | VCC |

### U15: 74HC154(4-16 译码)

| Pin | 信号 | 连接 |
|-----|------|------|
| A-D(12-15) | step[3:0] | U10(hc161).Q0-Q3 |
| G1, G2(18,19) | decode_disable | U17(hc32).Y1 |
| Y1, Y3, Y5, Y7, Y9 | latch_xxx_n | U5-U9./Enable |
| Y13 | dac_clk_n | U16(hc04).A1(反相) |
| 24 | VDD | VCC |
| 12 | GND | GND |

### U16: 74HC04 #2(三路反相,core.v)

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 | A1 | dac_clk_n(U15.Y13) |
| 2 | Y1 | latch_dac → U30(hc273).CP |
| 3 | A2 | SPFM_RST_n |
| 4 | Y2 | rst_n_inv → U17(hc32).A1 |
| 5 | A3 | SPFM_CS_n |
| 6 | Y3 | cs_n_inv → U17(hc32).B1 |
| 9-12 | A4-A6/Y4-Y6 | GND(未用) |
| 7 | GND | GND |
| 14 | VDD | VCC |

### U17: 74HC32(或门,core.v)

| Pin | 信号 | 连接 |
|-----|------|------|
| 1 | A1 | rst_n_inv(U16.Y2) |
| 2 | B1 | cs_n_inv(U16.Y3) |
| 3 | Y1 | decode_disable → U15(hc154).G1/G2 |
| 4-6, 9-12 | 其他 3 路 | GND(未用) |
| 7 | GND | GND |
| 14 | VDD | VCC |

---

## 净网络表(关键信号)

| 网络 | 源 | 终点 |
|------|------|------|
| STEP_CLK | Y1 | U10.CP, U11.CP, U5-U9.CLK |
| SPFM_CLK | 外部 CPU | U2.CLK, U3.CLK |
| SPFM_CS_n | 外部 CPU | U18-U22.Select, U16.A3(反相路径) |
| SPFM_RST_n | 外部 CPU | U2./CLR, U10.CEP/CET, U11.CET, U12.B1, U16.A2, U30./MR |
| step[0:3] | U10.Q0-Q3 | U13.A0-A3, U15.A-D |
| step[4] | U11.Q0 | U13.A4, U18.B1 |
| step[5] | U11.Q1 | U13.A5, U19.B1 |
| tc_lo | U10.TC | U12.A1 |
| step_hi_cep | U12.Y1 | U11.CEP |
| addr_wr_pulse_n | U4.Y1 | U3./Enable |
| data_wr_pulse_n | U4.Y2 | U22.A1 |
| rst_n_inv | U16.Y2 | U17.A1 |
| cs_n_inv | U16.Y3 | U17.B1 |
| decode_disable | U17.Y1 | U15.G1/G2 |
| dac_clk_n | U15.Y13 | U16.A1 |
| latch_dac | U16.Y1 | U30.CP |
| Y1-Y9 (154) | U15 | U5-U9./Enable |
| ucode[7] | U13.DQ7 | U22.B2 |
| ucode[6] | U13.DQ6 | U22.B1 |
| ucode[2:0] | U13.DQ[2:0] | U18.B1-B3, U23.Select |
| reg_a[15:0] | U5+U6.Q | U26-U29.A, U14.A0-A6 |
| reg_b[15:0] | U7+U8.Q | U26-U29.B |
| reg_c[3:0] | U9.Q0-Q3 | U14.A7-A10 |
| c4_0,c4_1,c4_2 | U26-U28.C4 | U27-U29.C0 |
| adder_lo[7:0] | U26+U27.S | U23+U24.A |
| adder_hi[7:0] | U28+U29.S | U23+U24.B |
| writeback_data | U23+U24.Y | U20+U21.B |
| ram_addr[7:0] | U18+U19.Y | U25.A0-A7 |
| ram_di[7:0] | U20+U21.Y | U25.DI |
| ram_do[7:0] | U25.DO | U5-U9.D |
| ram_we_n | U22.Y1 | U25.WE_n |
| ram_oe_n | U22.Y2 | U25.OE_n |
| wave_do[7:0] | U14.DQ | U30.D |
| dac_out[7:0] | U30.Q | R-2R DAC → RC 低通 → LM386 |

---

## 隐藏门审计结果

```bash
$ grep -nE "~|&|\|\||\^" rtl/wt3_core.v | grep -v "//"
(空)

$ grep -nE "~|&|\|\||\^" rtl/wt3_spfm_bus.v | grep -v "//"
53: wire le = ~(CS_n | WR_n);              # 外部协议, 边界外
54: wire write_active = ~CS_n & ~WR_n & RST_n;
55: wire addr_wr_comb = write_active & ~A0;
56: wire data_wr_comb = write_active & A0;
```

**结论**:wt3_core.v 内部 0 个隐藏逻辑门,wt3_spfm_bus.v 剩余 4 处都是 SPFM 外部协议译码(声卡边界外,不算隐藏门)。

---

## DAC 后端(模拟部分,不算 IC)

```
U30.Q[7:0] ──→ R-2R 阶梯(20kΩ/10kΩ 0.1%) ──→ V_analog
                                                   │
                                                   ├──→ RC 一阶低通(R=820Ω, C=10nF, fc≈19kHz)
                                                   │
                                                   ↓
                                              LM386 音频放大
                                                   │
                                                   ↓
                                                  喇叭
```

---

## 验证结果(v1.4)

```
=== WSG v1.4 C-E-G-C5 Cascade + Piano Envelope ===
设置: 4 通道 vol=0, 触发时升至 15, 按 piano_env 衰减到 7 sustain
触发时刻: ch0=0ms (C4), ch1=200ms (E4), ch2=400ms (G4), ch3=600ms (C5)
采集 1.2s = 230400 latch (192kHz TDM)

Final RAM state:
  ch0: acc=0x7d6d step=0x0165 vol=0x07   ✓ C4 261Hz
  ch1: acc=0x8200 step=0x01c2 vol=0x07   ✓ E4 330Hz
  ch2: acc=0x3900 step=0x0217 vol=0x07   ✓ G4 392Hz
  ch3: acc=0x8a17 step=0x02ca vol=0x07   ✓ C5 523Hz

Generated wt3_piano.wav (192kHz 单声道, 1.2s) — 听感验证 PASS
```

---

## v1.0 → v1.4 演进

| 版本 | IC 数 | 改动 |
|------|-------|------|
| v1.0 | 17 | 初版单通道(隐藏 373/174 reg 模拟) |
| v1.1 | 18 | 显式实例化 hc373 + hc174 |
| v1.2 | 19 | +1 片 377(reg_c volume),wavetable 4KB |
| v1.3 | 19 | 4 通道 TDM 数字混音(仍有隐藏反相器) |
| **v1.4** | **30** | **16-bit phase_acc; +2×377 +2×283 +1×154 +1×157 +2×04 +1×08 +1×32; 声卡内部 0 隐藏门** |
