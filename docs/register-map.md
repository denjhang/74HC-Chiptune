# WT3 WSG 寄存器映射表（外部 CPU 接口）

**版本**: v1.1（加入 volume 寄存器）
**更新日期**: 2026-06-14
**适用**: 单通道 WSG（声卡模块从 373 入口之后开始）

---

## 寄存器映射

CPU 通过 SPFM 总线访问下列地址。YM2413 风格双步写：
1. `SPFM_A0=0, SPFM_D=reg_addr` → 锁存寄存器地址
2. `SPFM_A0=1, SPFM_D=reg_data` → 写入数据

| 地址 | 名称 | 位宽 | 读写 | 默认值 | 说明 |
|------|------|------|------|--------|------|
| 0x00 | phase_acc | 8-bit | R/W | 0x00 | 相位累加器当前值。CPU 一般不写，由微码每周期自动累加；可写用于初值设定或软复位 |
| 0x01 | phase_step | 8-bit | W | 0x00 | **频率参数**：每采样周期的相位增量。决定音高 |
| 0x02 | volume | 4-bit | W | 0x00 | **音量参数**：0-15 共 16 级。低 4 位有效，高 4 位忽略 |

---

## 参数说明

### phase_step（频率）

频率计算公式：
```
freq = phase_step × sample_rate / wavetable_size
     = phase_step × 96000 / 256
     = phase_step × 375 Hz
```

| phase_step | 频率 | 音域 |
|-----------|-------|------|
| 0x01 | 375 Hz | |
| 0x02 | 750 Hz | |
| 0x04 | 1500 Hz | |
| 0x08 | 3000 Hz | 测试默认 |
| 0x10 | 6000 Hz | |
| 0x20 | 12000 Hz | |
| 0x40 | 24000 Hz | |
| 0x80 | 48000 Hz | 接近 Nyquist |

**约束**: phase_step ≤ 0x80（≥ 0x81 一个周期不足 2 个采样点，会产生混叠）

### volume（音量）

4-bit 精度，16 级。wavetable ROM 内预存每个音量级别的 256 字节 sine 表，CPU 写入后硬件查表自动衰减。

| volume | 振幅 | dB |
|--------|------|-----|
| 0x0 | 0 (静音) | -∞ |
| 0x1 | 振幅 × 1/15 | -23.5 |
| 0x2 | 振幅 × 2/15 | -17.5 |
| ... | ... | ... |
| 0x8 | 振幅 × 8/15 | -5.5 |
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

// 播放 3000Hz、音量 10/15 的正弦波
spfm_write(0x01, 0x08);   // 频率 = 3000Hz
spfm_write(0x02, 0x0A);   // 音量 = 10/15

// phase_acc 不需要写，硬件自动累加
// 修改频率/音量随时生效（下个微码循环开始用新值）
```

---

## 软件包络（CPU 实时更新 volume）

音量寄存器可在任意时刻重写，下个微码循环（32 step ≈ 10.4μs）生效。CPU 按时间表更新 volume 实现包络，**硬件 0 改动**。

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

// 主循环
spfm_write(0x01, freq);           // 设频率
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

### 包络类型示例

| 乐器 | Attack | Decay | Sustain | Release |
|------|--------|-------|---------|---------|
| 钢琴 | <5ms→15 | 30ms→9 | 持续衰减 | 1.5s→0 |
| 风琴 | <5ms→15 | 无 | 满档保持 | 200ms→0 |
| 弦乐 | 200ms→15 | 无 | 满档 | 500ms→0 |
| 鼓 | <1ms→15 | 50ms→0 | - | - |

CPU 端只需更换 `*_envelope()` 函数即可换乐器。

---

## 地址分配逻辑

| RAM 地址 | 用途 | 写入者 |
|---------|------|--------|
| 0x00 | phase_acc | 微码自动写回（283 加法结果） |
| 0x01 | phase_step | CPU 写（决定频率） |
| 0x02 | volume | CPU 写（决定音量） |

CPU 不应直接写 RAM[0]（phase_acc），因为下个微码周期会被加法结果覆盖。如需重置相位，写 0x00 后立刻让 CPU 同步等待一个完整微码循环（32 step）。

---

## 变更历史

| 版本 | 日期 | 变更 |
|------|------|------|
| v1.0 | 2026-06-14 | 初版：phase_acc (0x00), phase_step (0x01) |
| v1.1 | 2026-06-14 | **加入 volume (0x02)**，wavetable ROM 地址扩展 A8-A11 |
| v1.2 | 2026-06-14 | 加入软件包络使用说明（CPU 实时更新 volume） |
