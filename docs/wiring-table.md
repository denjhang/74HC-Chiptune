# WT3 WSG 4 通道 TDM 接线表（v1.3）

**生成日期**: 2026-06-14
**版本**: v1.3（4 通道 TDM 数字混音）
**核对来源**: [rtl/wt3_core.v](../rtl/wt3_core.v) + [rtl/wt3_spfm_bus.v](../rtl/wt3_spfm_bus.v) 实际 module 实例化
**验证**: 4 通道 TDM 测试 PASS（5/5）

---

## 芯片清单（19 IC，全部显式实例化）

| # | 位号 | 型号 | 封装 | 功能 | 实例名 | 文件:行 |
|---|------|------|------|------|--------|---------|
| 1 | U1 | 74HC373 | DIP-20 | SPFM D[7:0] 透明锁存 | u_d_latch | spfm_bus.v:64 |
| 2 | U2 | 74HC174 | DIP-16 | 同步器 (3+2 级 D-FF) | u_sync | spfm_bus.v:89 |
| 3 | U3 | 74HC377 | DIP-20 | SPFM 地址寄存器 | u_addr_reg | spfm_bus.v:116 |
| 4 | U4 | 74HC377 | DIP-20 | reg_a（phase_acc 锁存） | u_reg_a | core.v:283 |
| 5 | U5 | 74HC377 | DIP-20 | reg_b（phase_step 锁存） | u_reg_b | core.v:293 |
| 6 | U6 | 74HC377 | DIP-20 | reg_c（volume 锁存） | u_reg_c | core.v:303 |
| 7 | U7 | 74HC161 | DIP-16 | step_lo (step[3:0]) | u_step_lo | core.v:230 |
| 8 | U8 | 74HC161 | DIP-16 | **step_hi (step[5:4])** ← v1.3: 6-bit | u_step_hi | core.v:238 |
| 9 | U9 | 39SF040 | DIP-32 | **微码 ROM（64 字节，4 通道×16 step）** | u_mc | core.v:252 |
| 10 | U10 | 39SF040 | DIP-32 | wavetable ROM（4KB = 16 vol×256 phase） | u_wave | core.v:340 |
| 11 | U11 | 74HC157 | DIP-16 | RAM 地址 mux 低 4 位 | u_addr_lo | core.v:130 |
| 12 | U12 | 74HC157 | DIP-16 | RAM 地址 mux 高 4 位 | u_addr_hi | core.v:151 |
| 13 | U13 | 74HC157 | DIP-16 | RAM DI mux 低 4 位 | u_di_lo | core.v:171 |
| 14 | U14 | 74HC157 | DIP-16 | RAM DI mux 高 4 位 | u_di_hi | core.v:180 |
| 15 | U15 | 74HC157 | DIP-16 | RAM WE/OE 选择 | u_we_oe_mux | core.v:199 |
| 16 | U16 | CY62256 | DIP-28 | 参数 RAM（32KB, v1.3 用 16B） | u_ram | core.v:266 |
| 17 | U17 | 74HC283 | DIP-16 | 加法器低 4 位 | u_adder_lo | core.v:317 |
| 18 | U18 | 74HC283 | DIP-16 | 加法器高 4 位 | u_adder_hi | core.v:325 |
| 19 | U19 | 74HC273 | DIP-20 | DAC 输出锁存（8-bit, TDM 4 通道共享） | u_dac | core.v:358 |

**外部元件（不计入 IC 数）**:
- Y1: 3.072MHz 晶振（HC-49S 或 3225 SMD）
- DAC: 8-bit R-2R 电阻网络（20kΩ/10kΩ 0.1%）
- 低通滤波: RC 一阶（截止 ~5 kHz）+ 音频放大器（LM386 或类似）
- C1-C19: 每片 IC 的 0.1μF 去耦

**相比 v1.2**: **0 新增 IC**。step 计数器从 5-bit 改 6-bit（U8 多用 1 个 Q）；微码 ROM 从 32B 扩到 64B（U9）；RAM 从 3B 扩到 16B（U16）。3.072MHz 主频不变。

---

## 全局网络

| 网络 | 说明 | 源 |
|------|------|------|
| VCC | +5V | 电源 |
| GND | 地 | 电源 |
| STEP_CLK | 3.072MHz 主时钟（48kHz × 64 step） | Y1 晶振 |
| SPFM_CLK | 10MHz（主机 SPFM 总线时钟） | 外部 CPU |
| SPFM_RST_n | 复位（低有效） | 外部 CPU |
| SPFM_D[7:0] | SPFM 数据总线 | 外部 CPU 驱动 |
| SPFM_A0 | 地址/数据选择 | 外部 CPU |
| SPFM_CS_n | 片选（低有效） | 外部 CPU |
| SPFM_WR_n | 写使能（低有效） | 外部 CPU |
| SPFM_RD_n | 读使能（低有效） | 外部 CPU（本设计未用） |

---

## 外部协议译码（PCB 飞线，不算声卡内部门）

| 信号 | 表达式 | 用途 |
|------|--------|------|
| le | ~(CS_n \| WR_n) | 373 LE：CS=0 & WR=0 时透明 |
| write_active | ~CS_n & ~WR_n & RST_n | 主机写操作进行中 |
| addr_wr_comb | write_active & ~A0 | 写地址相位 |
| data_wr_comb | write_active & A0 | 写数据相位 |

---

## 微码控制字（v1.2 新分配）

8-bit 控制字字段（注意：v1.2 改了字段位置，加 latch_c_n）：

```
bit 7: ram_oe_n       (0=read RAM)
bit 6: latch_a_n      (0=latch reg_a)
bit 5: latch_b_n      (0=latch reg_b)
bit 4: latch_c_n      (0=latch reg_c, volume)  ← v1.2 新增
bit 3: latch_dac_clk  (1=latch dac on posedge)
bit 2: mc_we_n        (0=write adder back to RAM)
bit 1-0: ram_addr[1:0]
```

---

## 微码 64 步循环（v1.3: 4 通道 × 16 step = 64 step）

每通道 16 step = 8 工作 + 8 NOP。4 通道分时复用数据通路。

| step | ch | sub | ucode | 动作 |
|------|----|----|-------|------|
| 0-7 | 0 | 0-7 | 见下 | ch0 工作阶段 |
| 8-15 | 0 | 8-15 | 0xF4 | ch0 NOP（SPFM 可在此写参数） |
| 16-23 | 1 | 0-7 | 见下 | ch1 工作阶段 |
| 24-31 | 1 | 8-15 | 0xF4 | ch1 NOP |
| 32-39 | 2 | 0-7 | 见下 | ch2 工作阶段 |
| 40-47 | 2 | 8-15 | 0xF4 | ch2 NOP |
| 48-55 | 3 | 0-7 | 见下 | ch3 工作阶段 |
| 56-63 | 3 | 8-15 | 0xF4 | ch3 NOP |

每通道 8 个工作 step（sub 0-7）的微码：

| sub | ucode | 动作 |
|-----|-------|------|
| 0 | 0x74 | OE=0, addr=0（读 chX.phase_acc） |
| 1 | 0x34 | latch_a=0, OE=0, addr=0（U4 锁存） |
| 2 | 0x75 | OE=0, addr=1（读 chX.phase_step） |
| 3 | 0x55 | latch_b=0, OE=0, addr=1（U5 锁存） |
| 4 | 0x76 | OE=0, addr=2（读 chX.volume） |
| 5 | 0x66 | latch_c=0, OE=0, addr=2（U6 锁存） |
| 6 | 0xF0 | mc_we_n=0, addr=0（写回加法结果） |
| 7 | 0xFC | dac_clk 上升沿 → U19 锁存 wavetable 输出 |

**注**: 64 step 循环 = 48kHz 循环率（3.072MHz ÷ 64），每通道采样率 = 48kHz（TDM 复用）

---

## RAM 内容（v1.3 参数表，16 字节）

| RAM 地址 | 通道 | 字段 | 写入者 | 说明 |
|---------|------|------|--------|------|
| 0x00 | ch0 | phase_acc | 微码自动写回 | 相位累加值（CPU 一般不写） |
| 0x01 | ch0 | phase_step | CPU 写 | ch0 频率参数 |
| 0x02 | ch0 | volume | CPU 写 | ch0 音量参数 |
| 0x03 | ch0 | reserved | - | 预留 |
| 0x04 | ch1 | phase_acc | 微码自动写回 | |
| 0x05 | ch1 | phase_step | CPU 写 | ch1 频率参数 |
| 0x06 | ch1 | volume | CPU 写 | ch1 音量参数 |
| 0x07 | ch1 | reserved | - | 预留 |
| 0x08 | ch2 | phase_acc | 微码自动写回 | |
| 0x09 | ch2 | phase_step | CPU 写 | ch2 频率参数 |
| 0x0A | ch2 | volume | CPU 写 | ch2 音量参数 |
| 0x0B | ch2 | reserved | - | 预留 |
| 0x0C | ch3 | phase_acc | 微码自动写回 | |
| 0x0D | ch3 | phase_step | CPU 写 | ch3 频率参数 |
| 0x0E | ch3 | volume | CPU 写 | ch3 音量参数 |
| 0x0F | ch3 | reserved | - | 预留 |
| 0x10-0x7FFF | 未用 | - | - | 预留扩展 |

RAM 地址映射公式: `addr = channel × 4 + sub_addr`，详见 [register-map.md](register-map.md)

---

## 逐芯片接线

### U1: 74HC373 — SPFM D 锁存（[spfm_bus.v:64](../rtl/wt3_spfm_bus.v#L64)）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | /OE | GND（常输出） |
| 2 | Q0 | d_latch[0] → U3.D0, U13.A1, U14.A1 |
| 3 | D0 | SPFM_D[0] |
| 4 | D1 | SPFM_D[1] |
| 5 | Q1 | d_latch[1] |
| 6 | D2 | SPFM_D[2] |
| 7 | Q2 | d_latch[2] |
| 8 | D3 | SPFM_D[3] |
| 9 | Q3 | d_latch[3] |
| 10 | GND | GND |
| 11 | LE | le = ~(CS_n \| WR_n) |
| 12-19 | Q4-Q7 | d_latch[4:7] |
| 13,14,16,18 | D4-D7 | SPFM_D[4:7] |
| 20 | VDD | VCC |

### U2: 74HC174 — 同步器（[spfm_bus.v:89](../rtl/wt3_spfm_bus.v#L89)）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | /CLR | SPFM_RST_n |
| 2 | Q1 | addr_q1 → U2.D2 |
| 3 | D1 | addr_wr_comb（外部协议） |
| 4 | D2 | addr_q1 |
| 5 | Q2 | addr_q2 → U2.D3 |
| 6 | D3 | addr_q2 |
| 7 | Q3 | addr_q3 → addr_wr_pulse_n（取反）→ U3./Enable |
| 8 | GND | GND |
| 9 | CLK | SPFM_CLK |
| 10 | Q6 | (未用) |
| 11 | D6 | GND |
| 12 | Q5 | data_q2 → data_wr_pulse_n → U15.A1 |
| 13 | D5 | data_q1 |
| 14 | D4 | data_wr_comb（外部协议） |
| 15 | Q4 | data_q1 → U2.D5 |
| 16 | VDD | VCC |

### U3: 74HC377 — SPFM 地址寄存器（[spfm_bus.v:116](../rtl/wt3_spfm_bus.v#L116)）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | /Enable | addr_wr_pulse_n |
| 2-9,12,15,17,19 | Q[7:0] | reg_addr[7:0] → U11.A, U12.A |
| 3,4,7,9,13,14,16,18 | D[7:0] | d_latch[7:0]（U1.Q） |
| 11 | CLK | SPFM_CLK |
| 10 | GND | GND |
| 20 | VDD | VCC |

### U4: 74HC377 — reg_a（phase_acc，[core.v:261](../rtl/wt3_core.v#L261)）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | /Enable | latch_a_n = ucode[6]（U9.DQ6） |
| D[7:0] | DI | ram_do[7:0]（U16.DO） |
| 11 | CLK | STEP_CLK |
| Q[7:0] | reg_a_q | → U17/U18 加法器 A 输入, U10 wavetable 地址 A0-A7 |

### U5: 74HC377 — reg_b（phase_step，[core.v:271](../rtl/wt3_core.v#L271)）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | /Enable | latch_b_n = ucode[5] |
| D[7:0] | DI | ram_do[7:0] |
| 11 | CLK | STEP_CLK |
| Q[7:0] | reg_b_q | → U17/U18 加法器 B 输入 |

### U6: 74HC377 — reg_c（volume，[core.v:281](../rtl/wt3_core.v#L281)）— **v1.2 新增**

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | /Enable | latch_c_n = ucode[4]（U9.DQ4） |
| D[7:0] | DI | ram_do[7:0]（U16.DO） |
| 11 | CLK | STEP_CLK |
| Q[7:0] | reg_c_q | → U10 wavetable ROM A8-A11（仅 Q0-Q3 有效） |

### U7: 74HC161 — step_lo（[core.v:208](../rtl/wt3_core.v#L208)）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | /MR | VCC |
| 2 | CP | STEP_CLK |
| 3-5, 14 | D0-D3 | GND |
| 6,11,12,13 | Q0-Q3 | step[0:3] → U9.A0-A3 |
| 7, 10 | CEP, CET | VCC |
| 9 | /PE | VCC |
| 15 | TC | tc_lo → U8.CEP |
| 16 | VDD | VCC |
| 8 | GND | GND |

### U8: 74HC161 — step_hi（[core.v:238](../rtl/wt3_core.v#L238)）

v1.3: 6-bit step counter (U8 用 2 位 Q0=step[4], Q1=step[5])

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | /MR | VCC |
| 2 | CP | STEP_CLK |
| 6 | Q0 | step[4] → U9.A4 |
| 5 | Q1 | step[5] → U9.A5, U11.B1 (RAM addr mux 高 4 位选通道) |
| 7 | CEP | tc_lo（U7.TC） |
| 10 | CET | VCC |
| 9 | /PE | VCC |
| 11-13 | Q2-Q3 | (未用) |
| 15 | TC | (未用) |
| 16 | VDD | VCC |

### U9: 39SF040 — 微码 ROM（[core.v:252](../rtl/wt3_core.v#L252)）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 8-12 | A0-A4 | step[0:4]（U7.Q0-Q3, U8.Q0） |
| 13 | A5 | **step[5]**（U8.Q1）← v1.3 新接 |
| 1-7, 24-31 | A6-A18 | GND |
| 13-15, 18-22 | DQ0-DQ7 | ucode[7:0]（控制字） |
| 16 | VSS | GND |
| 17 | WE_n | VCC |
| 23 | CE_n | GND |
| 25 | OE_n | GND |
| 32 | VDD | VCC |

**ucode 字段映射**:
- ucode[7] → ram_oe_n_mc → U15.B2
- ucode[6] → latch_a_n → U4./Enable
- ucode[5] → latch_b_n → U5./Enable
- ucode[4] → latch_c_n → U6./Enable
- ucode[3] → latch_dac_clk → U19.CP
- ucode[2] → mc_we_n → U15.B1
- ucode[1:0] → mc_ram_addr → U11.B1, U11.B2

### U10: 39SF040 — wavetable ROM（[core.v:307](../rtl/wt3_core.v#L307)）— **v1.2 地址扩展**

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 12 | A0 | reg_a_q[0]（U4.Q0） |
| 11 | A1 | reg_a_q[1] |
| 10 | A2 | reg_a_q[2] |
| 9 | A3 | reg_a_q[3] |
| 8 | A4 | reg_a_q[4] |
| 7 | A5 | reg_a_q[5] |
| 6 | A6 | reg_a_q[6] |
| 5 | A7 | reg_a_q[7] |
| **28** | **A8** | **reg_c_q[0]（U6.Q0）** ← v1.2 |
| **25** | **A9** | **reg_c_q[1]** |
| **24** | **A10** | **reg_c_q[2]** |
| **21** | **A11** | **reg_c_q[3]** |
| 1-4, 23, 27, 29-31 | A12-A18 | GND |
| 13-15, 18-22 | DQ0-DQ7 | wave_do[7:0] → U19.D |
| 16 | VSS | GND |
| 17 | WE_n | VCC |
| 23 | CE_n | GND |
| 25 | OE_n | GND |
| 32 | VDD | VCC |

**ROM 内容**: 4KB = 16 个音量级别 × 256 字节 sine
- 地址 = (volume << 8) | phase
- sine[idx, vol] = round(128 + (sine_full[idx] - 128) × vol/15)
- 见 [rom/gen_wt3_wavetable.py](../rom/gen_wt3_wavetable.py)

### U11: 74HC157 — RAM 地址 mux 低 4 位（[core.v:99](../rtl/wt3_core.v#L99)）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | Select | SPFM_CS_n |
| A1-A3, A4 | reg_addr[0:3]（U3.Q） |
| B1, B2 | mc_ram_addr[0:1]（U9.DQ0-DQ1） |
| B3, B4 | GND |
| Y1-Y4 | ram_addr[0:3] → U16.A0-A3 |
| 15 | /Enable | GND |
| 16 | VDD | VCC |

### U12: 74HC157 — RAM 地址 mux 高 4 位（[core.v:120](../rtl/wt3_core.v#L120)）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | Select | SPFM_CS_n |
| A1-A4 | reg_addr[4:7] |
| B1-B4 | GND |
| Y1-Y4 | ram_addr[4:7] → U16.A4-A7 |
| 15 | /Enable | GND |
| 16 | VDD | VCC |

### U13: 74HC157 — RAM DI mux 低 4 位（[core.v:140](../rtl/wt3_core.v#L140)）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | Select | SPFM_CS_n |
| A1-A4 | reg_data[0:3]（U1.Q0-Q3） |
| B1-B4 | adder_lo[0:3]（U17.S） |
| Y1-Y4 | di_lo → ram_di[0:3] → U16.DI0-DI3 |
| 15 | /Enable | GND |
| 16 | VDD | VCC |

### U14: 74HC157 — RAM DI mux 高 4 位（[core.v:158](../rtl/wt3_core.v#L158)）

同 U13，A = reg_data[4:7], B = adder_hi[0:3]（U18.S），Y → ram_di[4:7] → U16.DI4-DI7

### U15: 74HC157 — RAM WE/OE 选择（[core.v:177](../rtl/wt3_core.v#L177)）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | Select | SPFM_CS_n |
| 2 | A1 | data_wr_pulse_n（U2.Q5 取反） |
| 3 | B1 | mc_we_n（U9.DQ2） |
| 4 | Y1 | ram_we_n → U16.WE_n |
| 5 | A2 | VCC |
| 6 | B2 | ram_oe_n_mc（U9.DQ7） |
| 7 | Y2 | ram_oe_n → U16.OE_n |
| 8 | GND | GND |
| 9, 12 | Y3, Y4 | (未用) |
| 10, 11, 13, 14 | A3, B3, A4, B4 | GND |
| 15 | /Enable | GND |
| 16 | VDD | VCC |

### U16: CY62256 — 参数 RAM（[core.v:244](../rtl/wt3_core.v#L244)）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1, 2, 22, 24-27 | A14, A12, A10, A11, A9, A8, A13 | GND |
| 3 | A7 | ram_addr[7]（U12.Y4） |
| 4-7 | A6-A3 | ram_addr[6:3] |
| 8-10 | A2-A0 | ram_addr[2:0] |
| 11-13, 16-20 | I/O0-I/O7 | DI/DO 双向 |
| 14 | VSS | GND |
| 15 | WE_n | ram_we_n（U15.Y1） |
| 21 | CE_n | GND（常选） |
| 23 | OE_n | ram_oe_n（U15.Y2） |
| 28 | VDD | VCC |

**RAM 内容**:
- 0x00: phase_acc（微码自动写回）
- 0x01: phase_step（CPU 写）
- 0x02: volume（CPU 写）
- 0x03-0x7FFF: 预留扩展

### U17: 74HC283 — 加法器低 4 位（[core.v:285](../rtl/wt3_core.v#L285)）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1, 3, 5, 6 | A3, A2, A1, A0 → reg_a_q[3:0] |
| 2, 4, 13, 12 | B3, B2, B1, B0 → reg_b_q[3:0] |
| 7 | GND | GND |
| 10 | C4 | adder_c4_lo → U18.C0 |
| 11 | C0 | GND |
| 12-15 | Σ0-Σ3 | adder_lo[0:3] → U13.B1-B4 |
| 16 | VDD | VCC |

### U18: 74HC283 — 加法器高 4 位（[core.v:293](../rtl/wt3_core.v#L293)）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1, 3, 5, 6 | A → reg_a_q[7:4] |
| 2, 4, 13, 12 | B → reg_b_q[7:4] |
| 7 | GND | GND |
| 10 | C4 | (未用) |
| 11 | C0 | adder_c4_lo（U17.C4） |
| 12-15 | Σ | adder_hi[0:3] → U14.B1-B4 |
| 16 | VDD | VCC |

### U19: 74HC273 — DAC 输出锁存（[core.v:324](../rtl/wt3_core.v#L324)）

| Pin | 信号 | 连接到 |
|-----|------|--------|
| 1 | /MR | SPFM_RST_n |
| 2-9, 12, 15, 16, 19 | Q[7:0] | dac_out[7:0] → R-2R DAC |
| 3, 4, 6, 8, 13, 14, 16, 18 | D[7:0] | wave_do[7:0]（U10.DQ） |
| 10 | GND | GND |
| 11 | CP | latch_dac_clk = ucode[3] |
| 20 | VDD | VCC |

---

## 净网络表（关键信号）

| 网络 | 源 | 终点 |
|------|------|------|
| STEP_CLK | Y1 | U7.CP, U8.CP, U4-U6.CLK |
| SPFM_CLK | 外部 CPU | U2.CLK, U3.CLK |
| SPFM_CS_n | 外部 CPU | U11-U15.Select |
| SPFM_RST_n | 外部 CPU | U2./CLR, U19./MR |
| step[0:3] | U7.Q0-Q3 | U9.A0-A3 |
| step[4] | U8.Q0 | U9.A4, U11.B2 (RAM 地址 mux 选通道) |
| step[5] | U8.Q1 | U9.A5, U12.B1 (RAM 地址 mux 选通道) ← v1.3 新增 |
| tc_lo | U7.TC | U8.CEP |
| ucode[7] | U9.DQ7 | U15.B2 (ram_oe_n_mc) |
| ucode[6] | U9.DQ6 | U4./Enable (latch_a_n) |
| ucode[5] | U9.DQ5 | U5./Enable (latch_b_n) |
| ucode[4] | U9.DQ4 | **U6./Enable (latch_c_n)** |
| ucode[3] | U9.DQ3 | U19.CP (latch_dac_clk) |
| ucode[2] | U9.DQ2 | U15.B1 (mc_we_n) |
| ucode[1:0] | U9.DQ[1:0] | U11.B1, U11.B2 (mc_ram_addr) |
| d_latch[7:0] | U1.Q | U3.D, U13.A (低 4), U14.A (高 4) |
| reg_addr[7:0] | U3.Q | U11.A, U12.A |
| reg_data[7:0] | U1.Q | U13.A, U14.A |
| ram_addr[0:3] | U11.Y | U16.A0-A3 |
| ram_addr[4:7] | U12.Y | U16.A4-A7 |
| ram_di[0:3] | U13.Y | U16.I/O0-I/O3 |
| ram_di[4:7] | U14.Y | U16.I/O4-I/O7 |
| ram_do[7:0] | U16.I/O | U4.D, U5.D, **U6.D** |
| ram_we_n | U15.Y1 | U16.WE_n |
| ram_oe_n | U15.Y2 | U16.OE_n |
| data_wr_pulse_n | ~U2.Q5 | U15.A1 |
| addr_wr_pulse_n | ~U2.Q3 | U3./Enable |
| reg_a_q[0:3] | U4.Q0-Q3 | U17.A, U10.A0-A3 |
| reg_a_q[4:7] | U4.Q4-Q7 | U18.A, U10.A4-A7 |
| reg_b_q[0:3] | U5.Q0-Q3 | U17.B |
| reg_b_q[4:7] | U5.Q4-Q7 | U18.B |
| **reg_c_q[0:3]** | **U6.Q0-Q3** | **U10.A8-A11 (volume 地址)** |
| adder_c4_lo | U17.C4 | U18.C0 |
| adder_lo[0:3] | U17.Σ | U13.B |
| adder_hi[0:3] | U18.Σ | U14.B |
| wave_do[7:0] | U10.DQ | U19.D |
| dac_out[7:0] | U19.Q | R-2R DAC |

---

## 验证结果

### v1.2 满档测试
```
SPFM write phase_acc=0x00, phase_step=0x08, volume=0x0F
After 1 cycle:
  reg_a_q = 0x00, reg_b_q = 0x08, reg_c_q = 0x0F
  adder_s = 0x08
  dac_out = 0x80 (sine[0, vol=15])
observed_max = 0xFF (满档振幅)
PASS (3/3)
```

### v1.2 钢琴包络测试
```
CPU 按时间表更新 volume:
  0-10ms   vol=15 (peak=127)
  10-30ms  vol=13 (peak=110)
  30-60ms  vol=11 (peak=93)
  60-100ms vol=9  (peak=76)
  100-200ms vol=7 (peak=59)
  200-350ms vol=5 (peak=42)
  350-600ms vol=3 (peak=25)
  600-1000ms vol=2 (peak=17)
  1000-1500ms vol=1 (peak=8)
  1500ms+  vol=0 (peak=0, 静音)
Generated wt3_piano.wav (1.562s)
```

---

## v1.0 → v1.1 → v1.2 → v1.3 演进

| 版本 | IC 数 | 改动 |
|------|-------|------|
| v1.0 | 17 | 初版单通道（隐藏 373/174 reg 模拟） |
| v1.1 | 18 | 显式实例化 hc373 + hc174，hc273 重命名 |
| v1.2 | 19 | +1 片 377 (reg_c volume)，wavetable 4KB，钢琴包络演示 |
| **v1.3** | **19** | **0 新增 IC！4 通道 TDM 数字混音。step 计数器 5→6-bit，微码 32→64B，RAM 3→16B，采样率 96→48kHz/ch** |
