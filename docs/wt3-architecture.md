# WT3 WSG v1.3 架构文档 — 4 通道 TDM 数字混音

## 1. 设计哲学

直接复刻 Namco Pac-Man WSG 的"分时刷新 + 单 DAC 串行输出"思路,
但简化为 **纯 TDM 数字混音**:

- 不需要 4066 模拟开关
- 不需要多个 DAC
- 不需要外部混音电路
- **只用 1 个 273 + 1 个 DAC**,4 通道分时复用,DAC 后 RC 低通还原

人耳无法分辨数百 μs 内的电压跳变,4 通道在 192 kHz 切换率下分时输出,
经 RC 低通滤波后听起来就是 4 路独立声音的混音。

## 2. 关键参数

| 参数 | 值 | 说明 |
|------|-----|------|
| STEP_CLK | **3.072 MHz** | 主时钟,Namco 同频 |
| 循环长度 | 64 step | 6-bit step 计数器 |
| 循环率 | 48 kHz | = 3.072M / 64 |
| 通道数 | **4** | ch0-ch3 |
| 每通道 step 数 | 16 | 8 工作 + 8 NOP |
| **每通道采样率** | **48 kHz** | 每循环每通道输出 1 个 DAC 样本 |
| DAC 物理切换率 | 192 kHz | = 4 通道 × 48k |
| 62256 时序余量 | 4.6× | 70ns tAA @ 325ns step |
| 39SF040 时序余量 | 5.9× | 55ns tAA @ 325ns step |

## 3. TDM 时间片 (64 step 完整循环)

```
step 0-15:  ch0 (8 工作 + 8 NOP)
step 16-31: ch1 (8 工作 + 8 NOP)
step 32-47: ch2 (8 工作 + 8 NOP)
step 48-63: ch3 (8 工作 + 8 NOP)
```

通道号 = `step[5:4]` (2 位, 0-3)
通道内 step = `step[3:0]` (4 位, 0-15)

## 4. 每通道 16 step 微码

```
工作阶段 (step 0-7):
  step 0: 读 phase_acc           (OE=0, addr=0)
  step 1: latch_a + 读 phase_acc (latch_a=0, OE=0, addr=0)
  step 2: 读 phase_step          (OE=0, addr=1)
  step 3: latch_b                (latch_b=0, OE=0, addr=1)
  step 4: 读 volume              (OE=0, addr=2)
  step 5: latch_c                (latch_c=0, OE=0, addr=2)
  step 6: writeback              (mc_we=0, addr=0, 写 adder 回 phase_acc)
  step 7: dac_clk 锁存 wavetable (上升沿锁存 ROM 输出到 273)

空闲阶段 (step 8-15):
  step 8-15: NOP (OE关, 所有 latch 关, mc_we 关)
  → 留给 SPFM 总线写参数,不打断合成
```

NOP 区间的作用: CPU 想改某通道参数时,在该通道的 NOP 窗口写入,
合成流程完全不受影响。

## 5. RAM 地址映射

5-bit RAM 地址 = `{step[5:4] (通道号), mc_ram_sub_addr[1:0] (通道内偏移)}`

```
RAM[0]  = ch0.phase_acc
RAM[1]  = ch0.phase_step
RAM[2]  = ch0.volume
RAM[3]  = ch0.reserved
RAM[4]  = ch1.phase_acc
RAM[5]  = ch1.phase_step
RAM[6]  = ch1.volume
RAM[7]  = ch1.reserved
RAM[8]  = ch2.phase_acc
RAM[9]  = ch2.phase_step
RAM[10] = ch2.volume
RAM[11] = ch2.reserved
RAM[12] = ch3.phase_acc
RAM[13] = ch3.phase_step
RAM[14] = ch3.volume
RAM[15] = ch3.reserved
```

62256 共 32KB,实际用 16 字节,余量 2048 倍。

## 6. 数据通路 (单通道 1 个循环内)

```
step 0-1: RAM[phase_acc] → reg_a (377 #1)
step 2-3: RAM[phase_step] → reg_b (377 #2)
step 4-5: RAM[volume] → reg_c (377 #3)
step 6:   adder (reg_a + reg_b) → writeback → RAM[phase_acc]
step 7:   wavetable ROM[{reg_c, reg_a}] → 273 → DAC
```

wavetable ROM 地址 (12 位):
- A[7:0]  = reg_a_q (相位累加值)
- A[11:8] = reg_c_q[3:0] (音量 0-15)

ROM 内部预存: `wave × (vol+1) / 16` 查表结果
- 总容量: 256 phase × 16 vol = **4 KB**
- 单通道采样数: 256
- 音量级数: 16

## 7. SPFM 总线接口 (CPU 端)

CPU 通过 YM2413 风格双步写协议访问:

```
写地址: A0=0, CS_n=0, WR_n=0 → addr 锁存到 377
写数据: A0=1, CS_n=0, WR_n=0 → 数据写入 RAM[addr]
```

CPU 写流程:
1. CPU 写 (addr=4, data=0x10) → ch1.phase_step = 0x10
2. CPU 在 ch1 的 NOP 窗口 (step 24-31) 内写,合成不冲突
3. 下次 ch1 工作 (step 16-23) 时读到新 phase_step

## 8. 模拟输出

```
273 锁存 wavetable 输出 (8 bit)
  ↓ 并行
R-2R 电阻网络 (DAC,外部)
  ↓ 模拟电压 (192 kHz 切换)
RC 低通滤波 (截止 ~5 kHz,1 阶)
  ↓ 平滑模拟混音
音频输出 (3.5mm 插座)
```

人耳无法分辨 < 1 ms 的电压跳变,
192 kHz 切换在 RC 滤波后表现为 4 通道连续叠加。

## 9. 频率公式

```
freq = phase_step × fs / 256
     = phase_step × 48000 / 256
     = phase_step × 187.5 Hz

示例:
  phase_step = 0x10 (16)  → freq = 3000 Hz
  phase_step = 0x15 (21)  → freq = 3937 Hz (钢琴 C5 附近)
  phase_step = 0x2C (44)  → freq = 8250 Hz (高音区)
```

## 10. 与 Namco Pac-Man WSG 对比

| 特性 | Pac-Man WSG | WT3 v1.3 |
|------|-------------|----------|
| 主频 | 6.144 MHz | 3.072 MHz |
| 循环率 | 96 kHz | 48 kHz |
| 通道数 | 3 | 4 |
| 每通道 step | 6 (5 加 + 1 出) | 16 (8 工作 + 8 NOP) |
| 加法器位宽 | 4 位 (16/20 位累加) | 8 位 (8 位累加) |
| 波形数 | 8 种 | 1 种 (sine) |
| 音量实现 | 1M ROM 查表 | wavetable ROM 预乘 |
| 模拟混音 | 3 DAC 并行 | **1 DAC + TDM + RC** |
| 总 IC 数 | 6 (3M/2K/2L/1K/1L/1M) | 17 (含 SPFM 总线/157/273) |

简化代价: 加法器从 4 位(多次复用)变 8 位(2 片 283 直接加),换得微码简单;
通道数从 3 增到 4;
模拟输出从 3 DAC 简化为 1 DAC + RC 滤波。

## 11. 关键不变量

- v1.3 相比 v1.2: **0 新增 IC**,只是把 step 计数器从 5-bit 提到 6-bit
- v1.3 相比 v1.2: 微码 ROM 从 32 字节扩到 64 字节 (39SF040 仍只用 64/512K)
- v1.3 相比 v1.2: RAM 占用从 3 字节扩到 16 字节 (62256 仍只用 16/32K)
- v1.3 相比 v1.2: wavetable ROM 容量不变 (仍 4 KB)
- 唯一实质变化: **数据通路在 4 通道间分时复用**
