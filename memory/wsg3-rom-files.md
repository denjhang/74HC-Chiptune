---
name: wsg3-rom-files
description: Pac-Man WSG 原版 ROM 文件位置、格式、用途，4 个文件的等价关系
metadata:
  type: reference
---

## 原版 ROM 文件位置

`D:\working\vscode-projects\74HC-Chiptune\reference\Namco WSG\rom\`

## 4 个文件关系

| 文件 | 格式 | 大小 | 等价关系 |
|------|------|------|---------|
| `82s126.1m` | BIN (二进制) | 256 字节 | 原始 dump |
| `82s126_1m.coe` | Xilinx COE | 1853 字节 | 从 BIN 转换，值完全等价 |
| `82s126.3m` | BIN | 256 字节 | 原始 dump |
| `82s126_3m.coe` | Xilinx COE | 1853 字节 | 从 BIN 转换，值完全等价 |

**结论**: `.coe` 是 `.bin` 的格式转换版，**直接看 BIN 文件即可**，不要看 COE。

## 芯片对应

| 文件 | 网表芯片 | 真实芯片 | 用途 |
|------|---------|---------|------|
| `82s126.3m` | U3 | Signetics 82S126 (256×4 PROM) | **3M 微码 PROM** — 4-bit 控制字 |
| `82s126.1m` | U10 | Signetics 82S126 (256×4 PROM) | **1M 波形 PROM** — 4-bit 波形数据 |

## 82S126 = Signetics 256×4 bipolar PROM

- 不是 27C256！网表用 27C256 是仿真替代
- 原版 Pac-Man WSG 实际就是两片 82S126
- 256×4 = 1Kb

## 3M 微码 PROM 数据分析 (82s126.3m)

前 128 字节有效，后 128 字节为 0x00。

数据模式 (每字节低 4 位有效):
- 大部分是 0x0F (NOP)
- 步骤开头有 0x0D (频率累加)
- 周期开头 0x07 (清零加法器)
- 周期末尾 0x0B (锁存输出)

## 1M 波形 PROM 数据分析 (82s126.1m)

256 字节全部有效，存波形采样数据 (每字节低 4 位 = 0-15 音量级)。

## 用法

在 wsg3_core.v 中:
- U3 (微码) = hc39sf040 加载 `82s126.3m`
- U10 (波形) = hc39sf040 加载 `82s126.1m`

注意: 39SF040 是 8-bit, 而 82S126 是 4-bit。需要把 BIN 文件按 nibble 展开，或只用低 4 位。
