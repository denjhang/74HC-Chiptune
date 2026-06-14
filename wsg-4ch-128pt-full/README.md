# WSG 4 通道 128 点 — 完整版(v1.4,30 IC,0 隐藏门)

74HC Chiptune 合成器的完整实现。Namco WSG 风格的硬件 wavetable 合成器,
全部用 74HC 系列 CMOS 逻辑 IC 搭建,**0 隐藏门**(所有 boolean 操作都在
显式 IC 内,无 `assign ~`/`&`/`|`)。

## 关键参数

| 参数 | 值 |
|------|-----|
| 通道数 | 4(TDM 共享 1 个 DAC) |
| 相位累加精度 | 16-bit(频率 0.73 Hz,全 88 键钢琴音域) |
| 波形点数 | 128 点/周期 |
| 音量级数 | 16 级(4-bit) |
| 波形种类 | sine(预留 4 种,扩展位 A[12:11]) |
| 采样率 | 48 kHz/通道(DAC 输出 192 kHz TDM) |
| 主时钟 | 3.072 MHz |
| 钢琴音域 | A0(27.5 Hz)~ C8(4186 Hz),误差 < 1 音分 |
| IC 数 | **30 片**(声卡内部 0 隐藏门) |

## 文件结构

```
wsg-4ch-128pt-full/
├── rtl/                # Verilog 源码
│   ├── wt3_core.v              # 顶层, 30 IC 实例化
│   ├── wt3_spfm_bus.v          # SPFM 总线接口 (3 IC + 1 反相器)
│   └── hc*.v × 13              # 74HC 芯片行为模型
├── tb/
│   └── wt3_core_tb.v           # C-E-G-C5 级联 + 钢琴包络测试
├── rom/
│   ├── wt3_microcode.hex       # 微码 ROM 镜像 (64B × 4 通道)
│   ├── wt3_wavetable.hex       # wavetable ROM 镜像 (8KB)
│   ├── gen_wt3_microcode.py    # 微码生成
│   ├── gen_wt3_wavetable.py    # wavetable 生成
│   └── wt3_csv2wav.py          # CSV → WAV (192kHz 单声道)
├── docs/
│   ├── wt3-architecture.md     # v1.4 架构详解
│   ├── wiring-table-v14.md     # 30 IC 完整接线表
│   ├── hc-chiptune-design.md   # 总体设计哲学
│   └── cmos-synth-3786.md      # 古董琴参考(JDQ49A/3786/M208B1)
├── out/
│   └── wt3_piano.wav           # 测试输出 (1.2s, 192kHz)
├── build_wt3.sh                # 一键编译+仿真
├── pack_v14.py                 # 打包 zip 脚本
└── wt3_wsg_v1.4_piano_cascade.zip  # 已打包的发布版
```

## 编译运行

环境:Windows + msys2 + 自建 iverilog(详见 `../docs/build-iverilog.md`)

```bash
./build_wt3.sh wt3_core_tb
# 生成 wt3_piano.csv (230400 个 TDM 采样)
python rom/wt3_csv2wav.py wt3_piano.csv wt3_piano.wav
# 播放 wt3_piano.wav (192kHz 单声道)
```

预期:听到 C4 → E4 → G4 → C5 每 0.2s 进一个音,每个音 attack→decay→sustain。

## 30 IC 清单

| 类别 | 数量 | 型号 |
|------|------|------|
| SPFM 总线接口 | 4 | 373, 174, 377, 04 |
| 数据寄存器 | 5 | 377 × 5 |
| Step 计数器 | 2 | 161 × 2 |
| 微码 ROM | 1 | 39SF040 |
| Wavetable ROM | 1 | 39SF040 |
| MUX | 7 | 157 × 7 |
| 译码器 | 1 | 154 |
| 反相器 | 1 | 04(总 2 片 04,见 SPFM + 这里) |
| 与门 | 1 | 08 |
| 或门 | 1 | 32 |
| 参数 RAM | 1 | CY62256 |
| 加法器 | 4 | 283 × 4 |
| DAC 锁存 | 1 | 273 |
| **总计** | **30** | |

## 设计要点

- **0 隐藏门**:`grep -nE "~&\|\|^" rtl/wt3_core.v | grep -v "//"` 返回空
- **16-bit 相位累加**:用 4 片 74HC283 级联,精度追平 STC32 wt.c
- **TDM 混音**:4 通道共享 1 个 DAC,RC 低通做"模拟叠加",省 4066 模拟开关
- **微码 RAM 包络**:vol 存 RAM,CPU 周期性 SPFM 写更新(非电容包络)
- **154 硬译码**:step[3:0] → 6 个 latch + dac_clk,避免微码 ROM 扩到 16-bit

## 与精简版的关系

这是 **full 版**(30 IC,16-bit 相位,128 点 sine)。
同目录下的 `wsg-lite/`(待建)将是 **≤10 IC 的挑战版**,可能用:
- 8-bit 相位(省 2× 377 + 2× 283)
- 32 点方波(省 wavetable ROM)
- 电容包络(省 vol 寄存器 + 包络 RAM)
- 见 [../docs/cmos-synth-3786.md](../docs/cmos-synth-3786.md) 第 4-5 节
