# WSG3 — Namco WSG 1980 1:1 复刻 (15 IC)

> **Pac-Man WSG 硬件复刻 + SPFM 总线接口**
> 12 片 WSG 核心 + 3 片 SPFM = 15 片

## 关键参数

| 参数 | 值 |
|------|-----|
| 通道数 | 3 方波 + 1 噪音 |
| 相位精度 | 16-bit (time-shared 加法器) |
| 波形 | 32 点 wavetable (Pac-Man 同款) |
| 音量 | 4-bit (4066 电阻网络) |
| 采样率 | 96 kHz (Pac-Mam 原版) |
| 主时钟 | 2 MHz |
| IC 数 | **15 片** (12 片 WSG + 3 片 SPFM) |

## 12 片 WSG 核心

完全复刻 Pac-Man 1980 板 (U2-U12):

| 位号 | 型号 | 功能 |
|------|------|------|
| U2 | 74HC04 | 时钟整形 |
| U3 | 39SF040 | wavetable ROM |
| U4-U7 | 74HC157×4 | 地址/数据 mux |
| U8 | 74HC283 | time-shared 加法器 |
| U9 | 74HC174 | 相位锁存 |
| U10 | CY62256 | 频率/音量 RAM |
| U11 | 74HC273 | 输出寄存器 |
| U12 | CD4066 | 模拟混音 |

## 3 片 SPFM 接口

| 位号 | 型号 | 功能 |
|------|------|------|
| U13 | 74HC373 | 数据锁存 |
| U14 | 74HC174 | 写脉冲同步 |
| U15 | 74HC377 | 地址寄存器 |

## 工作流程

1. 主机通过 SPFM 写频率/音量 → U10 RAM
2. time-shared 加法器 (U8) 在 4-5 拍内完成 1 通道相位累加
3. 相位输出当 U3 ROM 地址 → 波形查表
4. 波形 + 音量 → U11 锁存 → U12 (4066) 混音
5. RES-COM 求和 → R5-8 + C1 低通 → SOUND

## 编译运行

```bash
./build.sh wsg3_core_tb
# 生成 wsg3_piano.csv (96kHz 单声道)
python rom/csv2wav.py wsg3_piano.csv wsg3_piano.wav
# 播放 wsg3_piano.wav
```

## 文件结构

```
wsg3/
├── rtl/                 # Verilog 源码
├── tb/                  # 测试
├── rom/                 # ROM 镜像
├── docs/                # 文档
└── build.sh             # 编译脚本
```

## 参考

- [wsg3-architecture.md](docs/wsg3-architecture.md) — 详细架构
- [wsg-netlist-analysis.md](docs/wsg-netlist-analysis.md) — Pac-Man 网表逆向
- [wiring-table.md](docs/wiring-table.md) — 接线表
