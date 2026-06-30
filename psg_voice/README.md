# psg_voice — 单音 PSG (5 片 74HC 方波合成器)

最简可编程方波音源，demo / 面包板快速搭建用。参考 SN76489 / AY-3-8910 的核心机制（period 计数翻转），但用 74HC 的 **TC（计满标志）+ 同步预置** 代替独立比较器，并用 HC00 一片合并反相器+与门，压到 5 片。完整接线表见 [`docs/wiring-table.md`](docs/wiring-table.md)。

## 设计原理

经典 PSG（STC 工程 `ay8910.c` / `sn76489.c`）核心：
```c
count += 1;
if (count >= period) { toggle; count = 0; }
```

本设计用 hc161 自身的 TC 实现等价逻辑，**不用 hc85 比较器**：

```
计数器从 period 自增到 0xFF (256-period 步)
  → TC=1, 下个时钟 PE=0 同步预置回 period (重装)
  → TC 上升沿经同步 D 触发器消毛刺后, 驱动 T 触发器翻转 → 方波
```

**频率公式**：`f = clk / (2 × (256 - period))`

## 芯片清单（5 片，全 74HC 实例化）

| # | 型号 | 数量 | 职能 |
|---|------|------|------|
| 0 | 74LS373 | 1-2 | **电平转换层**（FT232H 3.3V → PSG 5V，实测必需）|
| 1 | 74HC373 | 1 | 8-bit 透明锁存器（host 写入 period，Q 接计数器 D 端供重装。替代无库存的 HC377） |
| 2 | 74HC161 | 2 | 8-bit 计数器（级联，TC 时从 HC373 重装 period） |
| 3 | 74HC00 | 1 | 四与非门（1 路 PE 反相 + 2 路 gate 与门，合并原 HC04+HC08） |
| 4 | **74HCT74** | 1 | 双 D 触发器（半片同步 TC 消毛刺 + 半片 T 翻转出方波。**必须 HCT，HC 高频失效**）|

> **合并技巧**：用德摩根律，HC00 一片同时实现 PE 反相（第1路输入短接当反相器）和 gate 与门（第2+3路两级与非）。比 HC04+HC08 方案省 1 片。
> **电平转换**：FT232H 3.3V 输出 < 74HC 的 VIH(3.5V)，必须经 LS373 转成 5V（详见 mcu-interface.md §1.6）。
> **HCT74**：toggle 触发器高频翻转，HC 在面包板环境下 A6+ 失效，必须用 HCT。

外部时钟建议 **64kHz**（甜点频率，覆盖 C3~C8 共 5 个八度，各音区步数充足）。

## 接口

| 信号 | 方向 | 说明 |
|------|------|------|
| `clk` | in | 计数时钟（建议 125kHz，**外部独立时钟，非 MCU**） |
| `rst_n` | in | 复位（低有效） |
| `period_in[7:0]` | in | host 写入的 period 值（MCU GPIO 直驱） |
| `period_le` | in | 锁存使能（高=透明跟随，低=锁存，接 HC373 LE） |
| `gate` | in | 1=发声，0=静音 |
| `wave_out` | out | 方波输出 |

**MCU 控制方式**：并行直驱，11 个 GPIO，0 额外芯片。完整接口规范（时序、音高编码、编程模型）见 [`docs/mcu-interface.md`](docs/mcu-interface.md)。

> 核心时序：MCU 把 period 放到 `period_in[7:0]`，`period_le` 拉高（HC373 透明跟随）→ 保持 ≥0.1μs → 拉低（锁存）。HC373 是电平敏感锁存，**不接 clk**，与 PSG 振荡完全解耦，任意时刻锁存都有效。仿真已验证（见 `tb/psg_mcu_if_tb.v`）。

## 音高表（@125kHz 时钟）

`period = 256 - 125000/(2×f)`

| 音名 | 频率 (Hz) | period | | 音名 | 频率 (Hz) | period |
|------|----------|--------|---|------|----------|--------|
| C4 | 261.6 | 17 | | C5 | 523.3 | 137 |
| D4 | 293.7 | 43 | | D5 | 587.3 | 150 |
| E4 | 329.6 | 66 | | E5 | 659.3 | 161 |
| F4 | 349.2 | 77 | | F5 | 698.5 | 169 |
| G4 | 392.0 | 97 | | G5 | 784.0 | 176 |
| A4 | 440.0 | 114 | | A5 | 880.0 | 185 |
| B4 | 493.9 | 129 | | B5 | 987.8 | 192 |

**覆盖范围**（125kHz + 8-bit）：约 **244Hz (B3) ~ 62.5kHz**，常用旋律音区（C4~C6）全在内。

> 想覆盖更低音（如 A2/A3），可降低外部时钟（如 31.25kHz → 覆盖 61Hz 起），或改用更宽计数器。

## 仿真验证

```bash
# 用项目自带工具链 (iverilog + vvp)
set PATH=D:\Program Files\oss-cad-suite\bin;D:\Program Files\oss-cad-suite\lib;%PATH%

cd psg_voice
iverilog -g2012 -o tb/psg_voice_tb.vvp -Wall ^
  ../rtl/hc373.v ../rtl/hc161.v ../rtl/hc00.v ../rtl/hc74.v ^
  rtl/psg_voice.v tb/psg_voice_tb.v
vvp tb/psg_voice_tb.vvp
```

实测结果（@64kHz，覆盖 C3~C8）：
```
A4 目标 440Hz, 实测 440Hz (44 个上升沿 / 12500 clk)  ✓
A5 目标 880Hz, 实测 880Hz (88 个上升沿 / 12500 clk)  ✓
Gate OFF: 0 个上升沿 (静音正常)                      ✓
Gate ON : 18 个上升沿 (发声正常)                      ✓
```

## 关键设计点：TC 毛刺消除

hc161 的 TC 是组合输出（`CET & Q==0xFF`），count 经历 0xFF 时会有瞬态毛刺，直接当 hc74 时钟会导致 T 触发器**多触发**（实测 toggle 翻转次数是预期的 1.5 倍 → 频率错误）。

**修复**：用 hc74 的一半做 D 触发器，把 TC 用 clk 同步一拍后再驱动 T 触发器。修复后实测频率完全精确。

> 这是真硬件也会遇到的问题，面包板搭的时候记得保留这级同步。

## 文件

```
psg_voice/
├── rtl/
│   └── psg_voice.v          # 74HC PSG 核心 RTL (计数+比较+翻转+gate)
├── tb/
│   ├── psg_voice_tb.v       # 音高 + gate 验证
│   ├── psg_debug_tb.v       # TC 毛刺定位 debug
│   └── psg_mcu_if_tb.v      # 接口时序验证
├── host/                    # FT232H 控制器 (Python)
│   ├── psg_ft232h.py        # PSG 控制类 (set_freq/note_on/note_off)
│   ├── play_songs.py        # ★ 歌曲播放器 (4 首儿歌循环)
│   ├── play_sweep_low.py    # C3-C8 跨八度扫频
│   ├── play_scale_loop.py   # C 大调音阶循环
│   ├── test_gpio_selfcheck.py  # 16 GPIO 自检
│   ├── test_running_all.py     # 16 GPIO 流水灯
│   └── diag_*.py            # 硬件诊断脚本
└── docs/
    ├── wiring-table.md      # 真实引脚接线表 (含 LS373 电平转换)
    ├── mcu-interface.md     # 控制器接口规范 (含电平兼容性)
    └── development-log.md   # 开发过程 + 硬件调试实录 (7 个 bug)
```

## 歌曲播放

`host/play_songs.py` 内置 4 首常见儿歌/简单旋律（简谱编写），循环播放：

| 歌曲 | 调性 | 音区 |
|------|------|------|
| 两只老虎 | C 大调 | C4-C5 |
| 小星星 | C 大调 | C4-C6 |
| 欢乐颂（贝多芬）| C 大调 | C4-C5 |
| 生日快乐 | C 大调 3/4 | C4-C6 |

```bash
cd psg_voice/host
python play_songs.py    # Ctrl+C 停止
```

支持简谱记法：音级 1-7（do-si）、休止 0、附点（1.5 拍）、八分音符（0.5 拍）、八度覆盖。节拍由 `beat_t` 控制（默认 0.3 秒/拍）。
