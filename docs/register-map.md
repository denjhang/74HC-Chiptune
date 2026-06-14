# WT3 WSG 寄存器映射表（外部 CPU 接口）

**版本**: v1.3（4 通道 TDM 数字混音）
**更新日期**: 2026-06-14
**适用**: 4 通道 WSG（声卡模块从 373 入口之后开始）

---

## 寄存器映射

CPU 通过 SPFM 总线访问下列地址。YM2413 风格双步写：
1. `SPFM_A0=0, SPFM_D=reg_addr` → 锁存寄存器地址
2. `SPFM_A0=1, SPFM_D=reg_data` → 写入数据

每个通道占用 4 字节，地址 = `channel × 4 + sub_addr`。

### 通道 0 (ch0, RAM[0..3])

| 地址 | 名称 | 位宽 | 读写 | 默认值 | 说明 |
|------|------|------|------|--------|------|
| 0x00 | phase_acc | 8-bit | R/W | 0x00 | 相位累加器。硬件自动累加，CPU 一般不写 |
| 0x01 | phase_step | 8-bit | W | 0x00 | **频率参数**：每采样周期相位增量 |
| 0x02 | volume | 4-bit | W | 0x00 | **音量参数**：0-15 共 16 级。低 4 位有效 |
| 0x03 | reserved | - | - | - | 预留 |

### 通道 1 (ch1, RAM[4..7])

| 地址 | 名称 | 说明 |
|------|------|------|
| 0x04 | phase_acc | ch1 相位累加器 |
| 0x05 | phase_step | ch1 频率参数 |
| 0x06 | volume | ch1 音量参数 |
| 0x07 | reserved | 预留 |

### 通道 2 (ch2, RAM[8..11])

| 地址 | 名称 | 说明 |
|------|------|------|
| 0x08 | phase_acc | ch2 相位累加器 |
| 0x09 | phase_step | ch2 频率参数 |
| 0x0A | volume | ch2 音量参数 |
| 0x0B | reserved | 预留 |

### 通道 3 (ch3, RAM[12..15])

| 地址 | 名称 | 说明 |
|------|------|------|
| 0x0C | phase_acc | ch3 相位累加器 |
| 0x0D | phase_step | ch3 频率参数 |
| 0x0E | volume | ch3 音量参数 |
| 0x0F | reserved | 预留 |

---

## 参数说明

### phase_step（频率）

每通道采样率 = **48 kHz**（与循环率相同，TDM 模式下每通道每循环刷新 1 次）。

频率计算公式：
```
freq = phase_step × sample_rate / wavetable_size
     = phase_step × 48000 / 256
     = phase_step × 187.5 Hz
```

| phase_step | 频率 | 音域 |
|-----------|-------|------|
| 0x01 | 188 Hz | 低音 |
| 0x02 | 375 Hz | |
| 0x04 | 750 Hz | |
| 0x08 | 1500 Hz | |
| 0x0A | 1875 Hz | 钢琴 A5 |
| 0x10 | 3000 Hz | 测试默认 |
| 0x15 | 4406 Hz | 钢琴 C5 附近 |
| 0x20 | 6000 Hz | |
| 0x40 | 12000 Hz | |
| 0x80 | 24000 Hz | 接近 Nyquist |

**约束**: phase_step ≤ 0x80（≥ 0x81 一个周期不足 2 个采样点，会产生混叠）

### volume（音量）

4-bit 精度，16 级。wavetable ROM 内预存每个音量级别的 256 字节 sine 表，CPU 写入后硬件查表自动衰减。

| volume | 振幅 | dB |
|--------|------|-----|
| 0x0 | 0 (静音) | -∞ |
| 0x1 | 振幅 × 1/15 | -23.5 |
| ... | ... | ... |
| 0xF | 振幅 × 15/15 = 满档 | 0 |

ROM 内 sine 公式（生成时）:
```
sine[idx, vol] = 128 + (sine_full[idx] - 128) × (vol / 15)
```

---

## 编程示例（C 伪代码）

```c
// SPFM 写寄存器
void spfm_write(uint8_t addr, uint8_t data) {
    spfm_set(A0=0, CS_n=0, WR_n=0, D=addr); wait();
    spfm_set(A0=0, CS_n=1, WR_n=1);                 wait();
    spfm_set(A0=1, CS_n=0, WR_n=0, D=data); wait();
    spfm_set(A0=1, CS_n=1, WR_n=1);                 wait();
}

// 和弦: ch0=C5, ch1=E5, ch2=G5, ch3=高八度 C6
spfm_write(0x01, 0x15); spfm_write(0x02, 0x0F);  // ch0: C5 满档
spfm_write(0x05, 0x1D); spfm_write(0x06, 0x0F);  // ch1: E5
spfm_write(0x09, 0x23); spfm_write(0x0A, 0x0F);  // ch2: G5
spfm_write(0x0D, 0x2B); spfm_write(0x0E, 0x0F);  // ch3: C6

// phase_acc 不需要写，硬件自动累加
// 4 通道在 64 step 循环内分时刷新, DAC 输出 TDM 混音
```

---

## 软件包络（CPU 实时更新 volume）

音量寄存器可在任意时刻重写，下个微码循环（64 step ≈ 20.8μs）生效。CPU 按时间表更新 volume 实现包络，**硬件 0 改动**。

### 钢琴式衰减（推荐曲线）

```c
uint8_t piano_envelope(uint32_t t_ms) {
    if (t_ms <    5)  return 15;  // attack (瞬间满档)
    if (t_ms <   10)  return 15;  // 短暂保持
    if (t_ms <   30)  return 13;  // 快速 decay 开始
    if (t_ms <   60)  return 11;
    if (t_ms <  100)  return  9;
    if (t_ms <  200)  return  7;
    if (t_ms <  350)  return  5;
    if (t_ms <  600)  return  3;
    if (t_ms < 1000)  return  2;
    if (t_ms < 1500)  return  1;
    return 0;                     // 静音
}

// 主循环 (每通道独立包络)
spfm_write(0x01, freq);           // ch0 设频率
uint8_t cur_vol = 0xff;
while (key_pressed) {
    uint8_t new_vol = piano_envelope(elapsed_ms());
    if (new_vol != cur_vol) {
        spfm_write(0x02, new_vol);  // 只在变化时写
        cur_vol = new_vol;
    }
    sleep_ms(1);                    // 1ms 查询
}
```

### 多通道独立包络

每通道维护各自的 elapsed_ms 和 envelope 函数。CPU 按 1ms 节拍轮询 4 通道。

```c
typedef struct {
    uint8_t addr_phase_step;
    uint8_t addr_volume;
    uint32_t start_ms;
    bool active;
} channel_t;

channel_t channels[4] = {
    {0x01, 0x02, 0, false},
    {0x05, 0x06, 0, false},
    {0x09, 0x0A, 0, false},
    {0x0D, 0x0E, 0, false},
};

void note_on(uint8_t ch, uint8_t freq) {
    channels[ch].active = true;
    channels[ch].start_ms = now_ms();
    spfm_write(channels[ch].addr_phase_step, freq);
}

void audio_tick(void) {
    for (uint8_t ch = 0; ch < 4; ch++) {
        if (!channels[ch].active) continue;
        uint32_t t = now_ms() - channels[ch].start_ms;
        uint8_t vol = piano_envelope(t);
        spfm_write(channels[ch].addr_volume, vol);
        if (vol == 0) channels[ch].active = false;
    }
}
```

---

## 地址分配逻辑

| RAM 地址 | 通道 | 字段 | 写入者 |
|---------|------|------|--------|
| 0x00, 0x04, 0x08, 0x0C | ch0-3 | phase_acc | 微码自动写回（283 加法结果） |
| 0x01, 0x05, 0x09, 0x0D | ch0-3 | phase_step | CPU 写（决定频率） |
| 0x02, 0x06, 0x0A, 0x0E | ch0-3 | volume | CPU 写（决定音量） |
| 0x03, 0x07, 0x0B, 0x0F | ch0-3 | reserved | 未使用 |

CPU 不应直接写 phase_acc，因为下个微码周期会被加法结果覆盖。

---

## 变更历史

| 版本 | 日期 | 变更 |
|------|------|------|
| v1.0 | 2026-06-14 | 初版：单通道 phase_acc, phase_step |
| v1.1 | 2026-06-14 | 加入 volume 寄存器 |
| v1.2 | 2026-06-14 | 加入软件包络使用说明 |
| v1.3 | 2026-06-14 | **4 通道 TDM 扩展**：每通道 4 字节，地址 = channel×4 + sub |
