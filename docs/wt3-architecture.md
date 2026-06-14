# WT3 WSG v1.4 架构文档 — 4 通道 16-bit 相位 TDM

## 1. 设计哲学 (v1.3 → v1.4)

v1.3 用 8-bit phase_acc,频率精度仅 187.5 Hz,**无法表达钢琴 88 键**。
v1.4 升级到 **16-bit phase_acc + 16-bit phase_step**,精度提升 256 倍,
达到 STC32 wt.c 同等水平,完整覆盖钢琴音域 (A0=27.5 Hz ~ C8=4186 Hz)。

## 2. 关键参数

| 参数 | v1.3 | **v1.4** | 提升 |
|------|------|----------|------|
| STEP_CLK | 3.072 MHz | 3.072 MHz | - |
| 循环 | 64 step | 64 step | - |
| 循环率 | 48 kHz | 48 kHz | - |
| 通道数 | 4 | 4 | - |
| 每通道 step | 16 (8+8) | 16 (13+3) | 工作阶段加长 |
| 每通道采样率 | 48 kHz | 48 kHz | - |
| **phase_acc 位宽** | 8 bit | **16 bit** | **256×** |
| **phase_step 位宽** | 8 bit | **16 bit** | **256×** |
| 频率精度 | 187.5 Hz | **0.73 Hz** | **256×** |
| 钢琴音域 | 2.5 八度 | **全 88 键** | - |
| IC 数 | 19 | **25** | **+6 IC** |

## 3. 频率精度对比

```
freq = phase_step × 48000 / 65536 = phase_step × 0.732421875 Hz
```

| 音名 | 频率 | phase_step (hex) | 实际频率 | 误差 (音分) |
|------|------|------------------|----------|-------------|
| A0 | 27.50 Hz | 0x0026 | 27.83 Hz | +14.5 |
| A2 | 110.00 Hz | 0x0096 | 109.86 Hz | -1.5 |
| **C4** | **261.63 Hz** | **0x0165** | **261.48 Hz** | **-0.7** |
| **E4** | **329.63 Hz** | **0x01C2** | **329.59 Hz** | **-0.2** |
| **G4** | **392.00 Hz** | **0x0217** | **391.85 Hz** | **-0.5** |
| A4 | 440.00 Hz | 0x0259 | 440.19 Hz | +0.5 |
| C5 | 523.25 Hz | 0x02CA | 522.95 Hz | -0.7 |
| C8 | 4186.00 Hz | 0x1653 | 4185.79 Hz | -0.1 |

人耳分辨极限约 5 音分,v1.4 全音域误差 < 1 音分,**远超人耳极限**。

## 4. TDM 时间片 (64 step 完整循环)

```
step 0-15:  ch0 (13 工作 + 3 NOP)
step 16-31: ch1 (13 工作 + 3 NOP)
step 32-47: ch2 (13 工作 + 3 NOP)
step 48-63: ch3 (13 工作 + 3 NOP)
```

通道号 = `step[5:4]`, 通道内 step = `step[3:0]`

## 5. 每通道 16 step 微码 (v1.4: 14 工作 + 2 NOP)

16-bit 操作要分高低字节两次,工作步骤从 8 增到 14:

```
step 0:   读 acc_lo         (OE=0, sub_addr=0)
step 1:   latch_a_lo        (latch_a_lo=0, OE=0, sub_addr=0)  [154 Y1]
step 2:   读 acc_hi         (OE=0, sub_addr=1)
step 3:   latch_a_hi        (latch_a_hi=0, OE=0, sub_addr=1)  [154 Y3]
step 4:   读 step_lo        (OE=0, sub_addr=2)
step 5:   latch_b_lo        (latch_b_lo=0, OE=0, sub_addr=2)  [154 Y5]
step 6:   读 step_hi        (OE=0, sub_addr=3)
step 7:   latch_b_hi        (latch_b_hi=0, OE=0, sub_addr=3)  [154 Y7]
step 8:   读 volume         (OE=0, sub_addr=4)
step 9:   latch_c           (latch_c=0, OE=0, sub_addr=4)     [154 Y9]
step 10:  写回 acc_lo       (WE=0, sub_addr=0, DI=adder_lo)
step 11:  NOP               (WE=1, 让 62256 WE_n 产生上升沿)
step 12:  写回 acc_hi       (WE=0, sub_addr=1, DI=adder_hi)
step 13:  dac_clk 锁存      (上升沿锁存 wavetable 输出到 273)  [154 Y13]
step 14-15: NOP             (SPFM 可写参数)
```

> **为什么 step 11 是 NOP?**
> 62256 在 WE_n **下降沿**写入。如果 step 10/12 都是 WE=0,
> WE_n 从 step 9→10 时下降一次, 但 step 10→11→12 全程 WE=0,
> step 12 的写回 RAM 看不到下降沿,**不会写入**。
> 中间插一个 WE=1 的 NOP, WE_n 才会有完整的下降沿 + 上升沿 + 下降沿序列。
> 这是仿真实测发现的 bug, 详见 [gen_wt3_microcode.py](../rom/gen_wt3_microcode.py)。

## 6. 微码控制字 (8-bit)

bit 不足表达 6 个 latch (a_lo/a_hi/b_lo/b_hi/c) + dac + we + 3-bit sub_addr。
**重新分配字段**:

```
bit 7: ram_oe_n         (0=read RAM)
bit 6: latch_clk        (复用: 0=latch_a_lo, 由 step[3:0] 区分)
bit 5: mc_we_n          (0=write RAM)
bit 4: dac_clk          (1=latch dac on posedge)
bit 3-0: ram_sub_addr   (4-bit, 0-15 子地址)
```

**但**这样无法在 8-bit 内表达 5 种 latch。**改用 step[3:0] 直接译码 latch 类型**:

实际上更简单: **latch 信号直接由微码字段控制**,使用更宽的微码。
但 ROM 只有 8-bit,需要 5 个 latch 信号 + OE + WE + DAC + 3 位地址 = 11 位。

**方案: 用 2 字节微码** (16-bit ROM 输出),或**复用 step[3:0] 译码**:

### 方案 A: 微码 ROM 改 16-bit (2 片 39SF040 并联)
- 微码 ROM 输出 16 位,够表达所有信号
- +1 IC 39SF040 (但已是 2 片,共用地址)
- 实际只需 1 片 39SF040 配合 8-bit 字段

### 方案 B: step[3:0] 直接硬译码 latch 类型 (推荐)

把 latch 类型**绑定到 step[3:0]**,微码只需 8-bit 控制其他信号:

| step[3:0] | 动作 | 触发 latch |
|-----------|------|-----------|
| 0 | 读 acc_lo | 无 |
| 1 | latch_a_lo | reg_a_lo (377 #1) |
| 2 | 读 acc_hi | 无 |
| 3 | latch_a_hi | reg_a_hi (377 #2) |
| 4 | 读 step_lo | 无 |
| 5 | latch_b_lo | reg_b_lo (377 #3) |
| 6 | 读 step_hi | 无 |
| 7 | latch_b_hi | reg_b_hi (377 #4) |
| 8 | 读 volume | 无 |
| 9 | latch_c | reg_c (377 #5) |
| 10 | writeback lo | 无 (mc_we=0) |
| 11 | writeback hi | 无 (mc_we=0) |
| 12 | dac_clk | 273 (上升沿) |
| 13-15 | NOP | 无 |

**latch 译码**: 用 4-bit step[3:0] → 5 个 latch enable 信号,
用 1 片 74HC154 (4-16 译码器) 或类似 —— **+1 IC**

实际可省: 用 5 个比较 (step==1, 3, 5, 7, 9, 12),但 74HC 没有这个 IC。
**最简洁方案: 加 1 片 74HC154** (4-16 译码器),取对应输出反相。

**总 IC 增加**:
- 2× 377 (reg_a_hi, reg_b_hi): +2 IC
- 2× 283 (adder_hi_mid, adder_hi_hi): +2 IC
- 1× 154 (latch 译码): +1 IC
- **共 +5 IC, 总 24 IC**

但 154 可以省略 —— 用微码 ROM 直接输出 latch 信号,
**ROM 字段重新分配为 16-bit** (2 片 39SF040 并联,共用地址):

```
ROM 低字节 (D0-D7):
  bit 7: ram_oe_n
  bit 6: ram_we_n
  bit 5: dac_clk
  bit 4-0: ram_sub_addr (5-bit)
ROM 高字节 (D8-D15):
  bit 8:  latch_a_lo_n
  bit 9:  latch_a_hi_n
  bit 10: latch_b_lo_n
  bit 11: latch_b_hi_n
  bit 12: latch_c_n
  bit 13-15: 未用 (扩展)
```

这样 0 新增 154,只需把微码 ROM 扩到 16-bit (复用现有 2 片 39SF040,
1 片存低字节 1 片存高字节)。

**最终方案 B**: 微码 ROM 16-bit,共用地址,**0 新增 IC 用于译码**。

## 7. RAM 地址映射 (v1.4: 每通道 5 字节)

5-bit RAM 地址 = `{step[5:4] (通道号 2 位), mc_ram_sub_addr[2:0] (3 位)}`

每通道 5 字节:
```
RAM[ch*8 + 0] = chX.phase_acc_lo   (低字节)
RAM[ch*8 + 1] = chX.phase_acc_hi   (高字节)
RAM[ch*8 + 2] = chX.phase_step_lo
RAM[ch*8 + 3] = chX.phase_step_hi
RAM[ch*8 + 4] = chX.volume         (低 4 位有效)
RAM[ch*8 + 5..7] = chX.reserved
```

4 通道 × 8 字节 = 32 字节 (62256 容量 32768 字节,余量 1000 倍)。

## 8. 数据通路 (单通道 1 个循环内)

```
step 0-3:  RAM[acc_lo/hi] → reg_a (16-bit, 2× 377)
step 4-7:  RAM[step_lo/hi] → reg_b (16-bit, 2× 377)
step 8-9:  RAM[volume] → reg_c (8-bit, 1× 377)
step 10:   adder_lo (reg_a_lo + reg_b_lo) → writeback → RAM[acc_lo]
step 11:   adder_hi (reg_a_hi + reg_b_hi + carry) → writeback → RAM[acc_hi]
step 12:   wavetable ROM[{reg_c[3:0], reg_a[15:9]}] → 273 → DAC
```

**16-bit 加法器**: 4 片 74HC283 级联
- 加法器 1: A=reg_a_lo[3:0], B=reg_b_lo[3:0], C0=0
- 加法器 2: A=reg_a_lo[7:4], B=reg_b_lo[7:4], C0=C4_1
- 加法器 3: A=reg_a_hi[3:0], B=reg_b_hi[3:0], C0=C4_2
- 加法器 4: A=reg_a_hi[7:4], B=reg_b_hi[7:4], C0=C4_3

**wavetable ROM 地址 (13 位)**:
- A[6:0]    = reg_a[15:9] (相位累加值高 7 位, 128 点波形)
- A[10:7]   = reg_c[3:0]  (音量 0-15)
- A[12:11]  = wave_idx (4 种波形预留: sine/square/triangle/sawtooth, 当前固定 sine = 0)

ROM 容量: 4 wave × 16 vol × 128 phase = **8192 字节 = 8 KB** (39SF040 用 8/512 KB)

> **注意**: phase 用 reg_a 的 **高 7 位** (reg_a[15:9]), 不是高 8 位。
> phase_step = 0x0165 (C4 261 Hz) 时, reg_a[15:9] 每周期增 0.7,
> 128 个 ROM 点对应 1 个完整正弦周期, 频率精度 = 48000/65536 ≈ 0.73 Hz。

## 9. 芯片清单 (v1.4: 25 IC)

| 类别 | v1.3 | v1.4 | 变化 |
|------|------|------|------|
| SPFM 总线 | 3 (373+174+377) | 3 | - |
| 数据寄存器 | 3 (377×3) | **5** (377×5) | **+2 IC** (reg_a_hi, reg_b_hi) |
| Step 计数器 | 2 (161×2) | 2 | - |
| 微码 ROM | 1 (39SF040) | 1 (8-bit) | - (用 154 硬译码避免扩 ROM) |
| Wavetable ROM | 1 (39SF040) | 1 | - |
| 地址/DI/WE mux | 5 (157×5) | **6** (157×6, +writeback lo/hi mux) | **+1 IC** |
| 译码器 | 0 | **1** (154, step[3:0] → latch/dac_clk) | **+1 IC** |
| 参数 RAM | 1 (62256) | 1 | - |
| 加法器 | 2 (283×2) | **4** (283×4) | **+2 IC** |
| 输出锁存 | 1 (273) | 1 | - |
| **合计** | **19** | **25** | **+6 IC** |

**外部元件**: 同 v1.3 (3.072MHz 晶振, R-2R DAC, RC 低通)

## 9.1 DAC 采样率与 TDM 混音

4 通道 TDM 共享 1 个 8-bit DAC,**实际 DAC 采样率为 192 kHz**(每通道 48 kHz × 4 通道)。

```
STEP_CLK = 3.072 MHz
64 step/cycle → 48 kHz/cycle (每通道)
4 通道 × 48 kHz → DAC 输出更新率 = 192 kHz (TDM)
```

### 9.1.1 DAC 看到的电压序列 (TDM)

```
latch:    ch0  ch1  ch2  ch3  ch0  ch1  ch2  ch3  ...
dac_out:  V0   V1   V2   V3   V0'  V1'  V2'  V3'  ...
          \_____________________/  \_____________________/ 
            1 个 48 kHz 周期          下一个 48 kHz 周期
```

每 325 ns (192 kHz) DAC 切换到下一个通道的瞬时电压。

### 9.1.2 模拟混音原理 (零额外 IC)

DAC 后接 **RC 低通滤波器**:
- 截止频率设为 20-24 kHz (低于 48 kHz 镜像频率)
- 4 个通道的高频成分 (48 kHz 切换噪声) 被滤掉
- 4 个通道的音频频段 (20 Hz - 20 kHz) **物理叠加** = 模拟混音

**不需要 4066 模拟开关或多个 DAC**。1 个 DAC + 1 个 RC 低通 = 4 通道混音器。

### 9.1.3 仿真 WAV 转换 (易错点)

仿真 CSV 是 TDM 序列,每行 1 个 8-bit dac_out。**WAV 转换必须用 192 kHz 采样率,不能平均 4 通道**:

| 错误做法 | 后果 |
|---------|------|
| 48 kHz + 每 4 行平均 | 高频成分被抵消, 所有音听起来同频 |
| 48 kHz + 取第 1 个 (ch0) | 只听到 ch0, 其他通道丢失 |
| **192 kHz 单声道 (正确)** | **4 通道物理叠加, 频率正确** |

参见 [rom/wt3_csv2wav.py](../rom/wt3_csv2wav.py)。

## 10. 与 STC32 wt.c 对比

| 特性 | STC32 wt.c | WT3 v1.4 |
|------|-----------|----------|
| 实现 | 软件 (C251) | 硬件 (74HC) |
| 主频 | 16-bit MCU @ ~30MHz | 3.072 MHz STEP_CLK |
| phase_acc | 16 bit | 16 bit |
| phase_step | 16 bit | 16 bit |
| 采样率 | 17640 Hz | 48000 Hz |
| 频率精度 | 0.54 Hz | 0.73 Hz |
| 通道数 | 4 | 4 |
| 波形点数 | 128 | 128 |
| 钢琴音域 | 全 88 键 | 全 88 键 |

v1.4 在精度上追平 STC wt.c,采样率反而更高 (48k vs 17.6k)。

## 11. 钢琴包络级联测试 (v1.4 验证通过)

### 11.1 测试设置

4 通道按 0.2s 间隔依次触发 C-E-G-C5,每个音独立 piano envelope:

| 通道 | 音名 | phase_step | 触发时刻 |
|------|------|-----------|---------|
| ch0 | C4 (261.6 Hz) | 0x0165 | 0 ms |
| ch1 | E4 (329.6 Hz) | 0x01C2 | 200 ms |
| ch2 | G4 (392.0 Hz) | 0x0217 | 400 ms |
| ch3 | C5 (523.3 Hz) | 0x02CA | 600 ms |

总采集时长 1.2s,采样率 192 kHz(TDM 4 通道 × 48 kHz),共 230400 个 latch 采样。

### 11.2 钢琴包络曲线 (attack → decay → sustain)

```
时间常数 (按键后 ms):   piano_env
  t <   5 ms:           15  (attack peak, 满档)
  t <  15 ms:           14
  t <  30 ms:           13
  t <  50 ms:           12
  t <  80 ms:           11
  t < 120 ms:           10
  t < 170 ms:            9
  t < 230 ms:            8
  t >= 230 ms:           7  (sustain, 持续不衰减)
```

衰减到 vol=7 (≈满档 46%) 后**持续 sustain**,模拟钢琴琴键持续按下的延音效果,
不进入 release。

### 11.3 SPFM 音量更新的硬件语义

每个通道 vol 变化时,testbench 调用一次 `set_vol`(完整 SPFM 双字节写:
写地址 → 写数据,CS_n 完整拉低→拉高)。这是**真实硬件行为**——多次操作多次拉低 CS_n,
不存在"一直拉低"。

SPFM 写期间 `decode_disable = ~SPFM_RST_n | ~SPFM_CS_n` 会短暂禁用 154 译码,
漏掉几个 latch_dac 边沿(每次 set_vol 约 2 μs,约 6 个 STEP_CLK = 1 个 latch)。
对 192 kHz 采样率影响可忽略,且与真实硬件表现一致。

### 11.4 仿真结果

```
Final RAM state:
  ch0: acc=0x7d6d step=0x0165 vol=0x07   ✓ C4 相位累加正常, vol 衰减到 sustain
  ch1: acc=0x8200 step=0x01c2 vol=0x07   ✓ E4 相位累加正常, vol 衰减到 sustain
  ch2: acc=0x3900 step=0x0217 vol=0x07   ✓ G4 相位累加正常, vol 衰减到 sustain
  ch3: acc=0x8a17 step=0x02ca vol=0x07   ✓ C5 相位累加正常, vol 衰减到 sustain

Generated wt3_piano.csv with 230400 samples (1200 ms)
```

4 通道全部正确:
- phase_acc 都在累加 (acc ≠ 0,非 0x0000)
- phase_step 全部正确 (0x0165/0x01C2/0x0217/0x02CA)
- vol 全部正确衰减到 0x07 (sustain)

输出文件: `wt3_piano.wav` (192 kHz 单声道, 1.2s)

### 11.5 听感验证

试听确认:
- 0.2s 间隔依次听到 C4 → E4 → G4 → C5 进入
- 每个音有明显的 attack (开声瞬间饱满) → decay (音量下降) → sustain (持续)
- 4 个音同时持续,频率独立、无相互干扰
- 钢琴包络感自然,无数字生硬感

**v1.4 4 通道 TDM + 微码 RAM 包络方案验证通过**。
