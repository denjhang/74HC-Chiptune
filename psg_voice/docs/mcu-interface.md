# psg_voice 控制器接口规范

控制器（MCU 或 FT232H）通过 GPIO **并行直驱**控制 PSG，无需额外芯片。本文定义信号、时序、寄存器语义和编程模型。

## 1. 硬件连接（并行直驱）

控制器用 11 个 GPIO 直接连 PSG 的裸信号：

| 控制器信号 | 方向 | PSG 端 | 说明 |
|---------|------|--------|------|
| `D[7:0]` | →PSG | `period_in[7:0]` | 8 位 period 数据（U1.D0~D7） |
| `LE` | →PSG | `period_le` | 写使能（= ~WE，高有效脉冲，接 U1.LE） |
| `GATE` | →PSG | `gate` | 门控（1=发声，0=静音，接 U4.A2） |
| ~~clk~~ | 外部 | `clk` | **不由控制器提供**，用独立 125kHz 时钟源（且 U1 不接 clk） |

> **clk 独立**：控制器不驱动 clk。PSG 自激振荡，控制器只在"换音/开关"时写寄存器，平时可休眠/做别的。

## 1.5 控制器选型

本项目实测可用两种控制器：

### 方案 A：FT232H（PC USB 桥接，**本项目实际采用**）

FT232H 用 D2XX + MPSSE 模式，提供 16 个可控 GPIO，无需写固件，直接 PC 上跑 Python。

**引脚分配（修正版：数据在 C 口，控制在 D4-D6）**：

| FT232H | PSG 信号 | 说明 |
|--------|---------|------|
| C0-C7 | period_in[7:0] | 8 位音高数据（0x82 命令一次写） |
| D4 | period_le | 写使能（LE 脉冲，HC373 锁存） |
| D5 | gate | 门控（1=发声，0=静音） |
| D6 | rst_n | 复位（低有效） |
| D0-D3, D7, C8+ | 备用 | 未用 |

> ⚠️ **MPSSE 引脚陷阱**：ADBUS 的 D0-D3 是 SPI 专用（TCK/TDI/TDO/TMS），**不能当 GPIO 可靠使用**。
> 特别是 **D1(TDI)/D2(TDO) 写 0 会被强制拉高**，导致数据被篡改（实测踩坑，见开发日志 Bug E）。
> 可靠 GPIO：**ACBUS C0-C7（8 个）+ ADBus D4-D7（4 个）**。
>
> C8/C9（ACBUS8/9）不在 MPSSE GPIO 字节范围内，不可运行时动态控制。

| 项 | 说明 |
|----|------|
| 驱动 | FTDI 官方 D2XX（Windows 自带 FTD2XX.dll），**无需 Zadig/libusb** |
| Python 库 | `pip install ftd2xx`（实测 1.3.8 可用） |
| 模式 | MPSSE（0x02），D 口用 0x80 写/0x81 读，C 口用 0x82 写/0x83 读 |
| 电平 | **3.3V 输出**，驱动 74HCT（VIH=2.0V）足够；驱动 74HC（VIH=3.5V）可能不够 |
| 速度 | GPIO 翻转 ~1MHz，写 LE 脉冲绰绰有余 |

> GPIO 验证：`host/test_gpio_selfcheck.py` 自检 D0-D7 + C0-C7 共 16 个脚全部可控；`host/test_running_all.py` 流水灯实测。

### 方案 B：MCU（STC/AVR/STM32/ESP32）

引脚够（≥11）的任意 MCU 都行，C 代码直驱。引脚紧用 SPI+HC595（见末尾替代方案）。

## 1.6 电平兼容性（⚠️ 关键教训，实测踩坑）

> **这是本项目最重要的硬件教训**：FT232H（3.3V）**不能直接**驱动 74HC 系列（VIH=3.5V），否则信号会被判成低电平，导致 PSG 完全不工作。

### 问题机理

FT232H 的 GPIO 输出高电平是 **3.3V**。74HC 的输入高电平阈值 VIH = VCC×0.7 = **3.5V**。

| 驱动 | 高电平 | 接收 | VIH | 能识别？ |
|------|--------|------|-----|---------|
| FT232H | 3.3V | 74HC | 3.5V | ❌ **不够**（被判低）|
| FT232H | 3.3V | 74**HCT** | **2.0V** | ✅ 够 |
| FT232H | 3.3V | 74**LS** | **2.0V** | ✅ 够 |
| 74HC（5V 供电）| 4.9V | 74HC | 3.5V | ✅ 够（片间互连无问题）|

### 实测症状（3.3V 电平不够时的表现）

- **period 不响应**：写 period 无效，计数器自由跑（Q0-Q7 恒定八度倍频）
- **gate 不发声**：toggle_q 有方波但 wave_out 无输出（gate 被 3.3V 判低，恒静音）
- **rst 锁死**：rst_n=3.2V 被判低，触发器持续清零，reload_pulse 恒 0
- **只有"敲击音"**：FT232H 写脉冲的瞬时电平跳变产生 transient，但无持续方波

### 解决方案：LS373（或 HCT）做电平转换层 ⭐

**实测有效方案**：在 FT232H 和 74HC 之间，加一片 **74LS373**（或 74HCT373）做电平转换。

```
FT232H (3.3V)      LS373 (VCC=5V, VIH=2.0V)      74HC PSG (5V)
─────────────      ────────────────────────      ─────────────
D0-D7 (3.3V) ───→ D0-D7 (识别✓)    Q0-Q7 (5V) ──→ period_in
C0-C2 (3.3V) ───→ D/LE (识别✓)      Q (5V) ────→ gate/rst_n
```

- LS373 的 VIH=2.0V（TTL 输入），3.3V 完全够
- LS373 由 5V 供电，Q 输出是干净的 5V 方波
- 下游所有 74HC 收到 5V 信号，完美识别

> **LS373 接法**：
> - **period 数据转换**：D0-D7 接 FT232H，LE 由 FT232H C0 控制（写脉冲时锁存），Q→period_in
> - **gate/rst 转换**：用其中 2-3 位，LE 接 VCC（常透明，纯当缓冲），Q→gate/rst_n

### 替代方案

| 方案 | 优点 | 缺点 |
|------|------|------|
| **LS373/HCT373 转换**（推荐）| 干净，输出 5V | 多 1-2 片芯片 |
| 全换 74HCT 系列 | 不加转换芯片 | 要换掉所有 74HC |
| 信号加 10kΩ 上拉到 VCC | 不加芯片 | LS 输出/上拉电阻取值要调，不如 LS373 可靠 |

> **教训**：3.3V 控制器（FT232H/现代 MCU）驱动 5V 74HC 系统，**必须过 TTL 电平器件（LS/HCT）**。
> 这个坑很隐蔽——信号"看起来有"（量得到电平、有咔哒音），但逻辑上被判低，导致整个系统静默。

### 补充教训：高频翻转场合必须用 HCT/AC（不能用 HC）

除了电平转换，还有一个独立的教训：**74HC74 在高频翻转场合不可靠，必须用 74HCT74**。

- 现象：toggle 触发器在 A6(1760Hz) 以上停止翻转，高音区没声音
- 根因：74HC 系列在面包板环境（寄生电容大、飞线长）下，高频翻转能力不足
- 解决：换 74HCT74，全音区恢复正常

> **规则**：涉及**高频翻转**或**窄脉冲采样**的器件（toggle D 触发器、同步 D 触发器、计数器高位），**优先选 HCT/AC 系列**，不要用 HC。HC 标称 f_max 虽高，但实际在寄生环境下表现差。

### 补充教训：8-bit period 的音区矛盾

PSG 的频率 `f = clk/(2×(256-period))`，period 是 8-bit（0~255）。这导致**低音覆盖和高音音准不可兼得**：

- 低音需要大 period → 需要低 clk
- 高音需要 period 远离 255（保证足够计数步数）→ 需要高 clk
- **64kHz 是甜点**：覆盖 C3~C8（5 个八度），各音区步数充足（C5 步数 61，C7 步数 15）

> 高音"没声音"的根因往往是 **period 步数太少**（计数器重装逻辑在极少步数时不稳定），不是器件频率极限。选时钟时要确保最高音的步数 ≥ ~10。

---

## 2. 寄存器模型（MCU 视角）

PSG 对外暴露 2 个"寄存器"（实际是硬件锁存/门控）：

| 寄存器 | 位宽 | 写法 | 作用 |
|--------|------|------|------|
| **PERIOD** | 8-bit | `MCU_D=值; MCU_LE↑; 等0.5μs; MCU_LE↓` | 设定音高（频率） |
| **GATE** | 1-bit | `MCU_GATE=1/0` | 开关声音 |

> 没有"读"操作，PSG 是只写设备。

---

## 3. 写时序（关键）

### 3.1 PERIOD 写时序

HC373 的 LE 本质就是写使能（WE），只是高有效（HC377 的 /WE 是低有效）。LE 下降沿把 D 锁进 Q：

```
MCU_D:  ----< 数据稳定 >----
              ↑               ↑
MCU_LE: _____|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|____   (默认低=不写)
              LE↑(打开)       LE↓(锁存)
```

**写步骤**（等价于 WE 的标准写法，极性反）：
1. MCU 把 period 放到 `MCU_D[7:0]`
2. `MCU_LE` 拉高（打开写入）
3. 保持 ≥0.1μs（建立时间）
4. `MCU_LE` 拉低（**下降沿锁存**）

**时序要求**：

| 参数 | 最小值 | 说明 |
|------|--------|------|
| `t_data_setup` | ≥ 0.1 μs | MCU_D 在 MCU_LE↑ 前稳定（HC373 建立时间） |
| `t_le_high` | ≥ 0.1 μs | MCU_LE 高电平宽度 |
| `t_data_hold` | ≥ 0.1 μs | MCU_LE↓ 后 MCU_D 保持（HC373 保持时间） |

> **与 HC377 的区别**：HC377 锁存要等 PSG 的 clk 上升沿（WE 低电平需覆盖一个 clk 周期 ≥8μs）；
> HC373 是电平锁存，LE 下降沿立即生效，**不依赖 clk**，写入更快（≥0.1μs 即可）。
> 对 MCU 来说就是写一个寄存器：HC377 用低脉冲 WE，HC373 用高脉冲 LE，仅极性不同。

### 3.2 GATE 写时序

`gate` 是纯电平信号，直接置 1/0，无时序约束。下个计数周期立即生效。

---

## 4. 音高编码（PERIOD 值 → 频率）

### 公式

```
频率 f = clk / (2 × (256 - PERIOD))
       = 125000 / (2 × (256 - PERIOD))   Hz   (@125kHz 时钟)
```

PERIOD 越大 → 频率越低。范围：

| PERIOD | 频率 | 音区 |
|--------|------|------|
| 0 | 244 Hz | ≈ B3 |
| 114 | 440 Hz | **A4**（标准音） |
| 185 | 880 Hz | **A5** |
| 255 | 62.5 kHz | 超声波（上限） |

### MCU 端频率换算（C 代码）

```c
// 频率 → PERIOD 寄存器值 (@125kHz 时钟)
// 输入: f (Hz), 输出: 8-bit PERIOD
uint8_t freq_to_period(uint16_t f_hz) {
    uint32_t period = 256UL - (125000UL / (2UL * f_hz));
    if (period > 255) period = 255;   // 限幅
    return (uint8_t)period;
}

// 示例
freq_to_period(440)  // = 114 (A4)
freq_to_period(880)  // = 185 (A5)
```

### 常用音高表（查表，零计算）

```c
// MIDI 音符 → PERIOD (@125kHz)。覆盖 C4(60)~B5(83)
const uint8_t midi_to_period[] = {
    // C4  D4  E4  F4  G4  A4  B4
       17, 43, 66, 77, 97,114,129,  // MIDI 60-66
    // C5  D5  E5  F5  G5  A5  B5
      137,150,161,169,176,185,192,  // MIDI 72-78
};
```

> 注：8-bit 量化在高音区（>2kHz）音准误差变大，demo 用足够。

---

## 5. 编程模型

### 5.1 底层驱动（移植到任意 MCU）

```c
// === 平台相关：替换为你的 MCU GPIO 操作 ===
#define PERIOD_PORT   P1        // 8 位端口接 period_in[7:0]
#define LE_PIN        P3_0      // 接 period_le (高=透明, 低=锁存)
#define GATE_PIN      P3_1      // 接 gate

static inline void bus_write(uint8_t v) { PERIOD_PORT = v; }
static inline void le_high(void)        { LE_PIN = 1; }  // 透明
static inline void le_low(void)         { LE_PIN = 0; }  // 锁存
static inline void gate_set(uint8_t g)  { GATE_PIN = g; }

// === 平台无关：PSG 接口 ===

// 写 PERIOD 寄存器 (HC373 透明锁存)
void psg_set_period(uint8_t period) {
    bus_write(period);
    le_high();       // 透明: Q 跟随 D
    delay_us(1);     // 建立时间
    le_low();        // 锁存: Q 固定
}

// 设频率（自动换算）
void psg_set_freq(uint16_t f_hz) {
    psg_set_period(freq_to_period(f_hz));
}

// note on / off
void psg_note_on(uint16_t f_hz) {
    psg_set_freq(f_hz);
    gate_set(1);
}

void psg_note_off(void) {
    gate_set(0);
}
```

### 5.2 演奏示例（旋律）

```c
// 旋律：C D E F G A B C
const uint16_t melody[] = {262,294,330,349,392,440,494,523};

void play(void) {
    for (int i = 0; i < 8; i++) {
        psg_note_on(melody[i]);
        delay_ms(300);      // 每音 300ms
        psg_note_off();
        delay_ms(50);       // 音间间隔
    }
}
```

### 5.3 简单包络（软件控制音量感）

PSG 本身只有开关（gate），但 MCU 快速开关 gate 可做"伪音量"：

```c
// 用 gate PWM 做衰减包络（占空比 = 音量感）
void note_on_envelope(uint16_t f_hz) {
    psg_set_freq(f_hz);
    for (int t = 0; t < 1000; t++) {   // 1 秒衰减
        uint8_t duty = piano_curve(t); // 0-100 占空比
        gate_set(1); delay_us(duty);
        gate_set(0); delay_us(100 - duty);
    }
    gate_set(0);
}
```

> 注：gate PWM 会让方波频率被调制，仅适合打击乐/短音。真正的音量需要加 DAC/电阻网络（见扩展章节）。

---

## 6. 复位与上电

| 信号 | 上电状态 | 说明 |
|------|---------|------|
| `rst_n` | 低→高 | 上电保持低 ≥1ms，然后拉高。清零计数器 + toggle |
| `MCU_GATE` | 0 | 上电静音，避免杂音 |
| `MCU_D` | 任意 | 复位期间 period_in 无所谓，rst_n 期间计数器被清零 |

```c
void psg_init(void) {
    // 1. 复位 PSG
    RST_PIN = 0;
    delay_ms(2);
    RST_PIN = 1;
    delay_us(10);

    // 2. 静音 + 设默认音
    gate_set(0);
    psg_set_period(114);   // A4 待命
}
```

---

## 7. 接口信号总表（速查）

| 信号 | MCU→PSG | 引脚数 | 时序 | 作用 |
|------|---------|--------|------|------|
| `period_in[7:0]` | → | 8 | 写时稳定 | 音高数据 |
| `period_le` | → | 1 | 高→低脉冲 | 锁存音高（HC373） |
| `gate` | → | 1 | 电平 | 开关声音 |
| `rst_n` | → | 1 | 上电低脉冲 | 复位 |
| `clk` | 外部 | 0 | 125kHz 连续 | 振荡（**非MCU**） |
| `wave_out` | ← | 1 | - | 方波输出→DAC |

**MCU 引脚合计：11 个 GPIO**（8 数据 + LE + GATE + RST）。

---

## 8. 替代方案（引脚紧张时）

### SPI + HC595（3 根线，加 1 片 74HC595）

若 MCU 引脚不足，用串行移位寄存器扩展：

```
MCU_SPI_MOSI ── HC595 SER
MCU_SPI_SCK  ── HC595 SRCLK
MCU_LATCH    ── HC595 RCLK
HC595.Q[7:0] ── period_in[7:0]
```

- 用 3 根 MCU 线代替 8 根数据线
- 加 1 片 74HC595，gate/rst 仍直驱
- 缺点：换音需移位 8 次（~几 μs），PSG 不再"纯 74HC 组合"（含移位寄存器）

> demo 阶段推荐并行直驱；产品化或多通道时再考虑 SPI。
