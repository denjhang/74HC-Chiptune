"""make_wt3_zip.py — 打包 WT3 WSG v1.3 里程碑 zip (4 通道 TDM)

包含: rtl 核心 + 微码/wavetable + testbench + 文档 + 生成脚本
排除: iverilog-install/, reference/, *.exe, 临时输出
"""

import zipfile
import os
from datetime import datetime

VERSION = "v1.3"
NAME = f"wt3_wsg_4ch_tdm_{VERSION}"
OUT_ZIP = f"{NAME}.zip"

INCLUDE = [
    # RTL 核心
    "rtl/wt3_core.v",
    "rtl/wt3_spfm_bus.v",
    "rtl/hc373.v",
    "rtl/hc174.v",
    "rtl/hc377.v",
    "rtl/hc273.v",
    "rtl/hc157.v",
    "rtl/hc161.v",
    "rtl/hc283.v",
    "rtl/hc39sf040.v",
    "rtl/hc62256.v",

    # ROM 内容 + 生成脚本
    "rom/wt3_microcode.hex",
    "rom/wt3_wavetable.hex",
    "rom/gen_wt3_microcode.py",
    "rom/gen_wt3_wavetable.py",

    # Testbench
    "tb/wt3_core_tb.v",
    "tb/wt3_piano_tb.v",

    # 文档
    "docs/register-map.md",
    "docs/wiring-table.md",
    "docs/wt3-architecture.md",

    # 辅助脚本
    "wt3_csv_to_wav.py",

    # 演示输出
    "wt3_sine.csv",
    "wt3_sine.wav",
]

README = f"""# {NAME}

WT3 WSG 4 通道 TDM 数字混音里程碑 (v1.3)

## 概要
- **19 IC 全部显式实例化, 0 新增 IC** (相比 v1.2)
- **4 通道 TDM 数字混音**: 1 个 273 + 1 个 DAC, 4 通道分时复用
- 主频 3.072MHz, 64 step 循环, 每通道采样率 48kHz
- 每通道 16 step = 8 工作 + 8 NOP (留给 SPFM 总线写参数)

## TDM 架构 (vs Namco Pac-Man)
| 特性 | Pac-Man | WT3 v1.3 |
|------|---------|----------|
| 通道数 | 3 | 4 |
| 主频 | 6.144 MHz | 3.072 MHz |
| 循环率 | 96 kHz | 48 kHz |
| 每通道采样率 | 96 kHz | 48 kHz |
| 模拟混音 | 3 DAC 并行 | **1 DAC + TDM + RC** |

人耳无法分辨数百 μs 内的电压跳变, 4 通道在 192 kHz 切换率下分时输出,
经 RC 低通滤波后听起来就是 4 路独立声音的混音。

## 芯片清单 (19 IC, 0 新增)
- 3 IC SPFM 总线: 373 + 174 + 377
- 3 IC 寄存器: 377 ×3 (reg_a + reg_b + reg_c)
- 2 IC step 计数器: 161 ×2 (级联 6-bit, v1.3 扩展)
- 2 IC ROM: 39SF040 (微码 64B) + 39SF040 (wavetable 4KB)
- 5 IC 选择器: 157 ×5
- 1 IC RAM: CY62256 (32KB, v1.3 用 16B)
- 2 IC 加法器: 283 ×2
- 1 IC 输出: 273 (TDM 4 通道共享)

## 寄存器表 (CPU 接口, 4 通道 × 4 字节)
| 地址 | 通道 | 字段 |
|------|------|------|
| 0x00-0x03 | ch0 | phase_acc/phase_step/volume/reserved |
| 0x04-0x07 | ch1 | phase_acc/phase_step/volume/reserved |
| 0x08-0x0B | ch2 | phase_acc/phase_step/volume/reserved |
| 0x0C-0x0F | ch3 | phase_acc/phase_step/volume/reserved |

频率公式: freq = phase_step × 48000 / 256 = phase_step × 187.5 Hz

## 编译运行
依赖: iverilog + vvp + Python 3

```bash
# 生成微码 + wavetable
python rom/gen_wt3_microcode.py
python rom/gen_wt3_wavetable.py

# 编译运行测试
iverilog -o wt3_core.vvp -Wall \\
    rtl/wt3_core.v rtl/wt3_spfm_bus.v \\
    rtl/hc373.v rtl/hc174.v rtl/hc377.v rtl/hc273.v \\
    rtl/hc157.v rtl/hc161.v rtl/hc283.v \\
    rtl/hc39sf040.v rtl/hc62256.v \\
    tb/wt3_core_tb.v

vvp wt3_core.vvp        # 4 通道 TDM 测试
python wt3_csv_to_wav.py wt3_sine.csv
```

## 演示音频
- wt3_sine.wav: 4 通道和弦 (3k/3.9k/5k/6k Hz) TDM 混音 0.5s

## v1.2 → v1.3 改动
- step 计数器 5-bit → 6-bit (U8 多用 1 位 Q1)
- 微码 ROM 32B → 64B (4 通道 × 16 step)
- RAM 占用 3B → 16B (4 通道 × 4 字节)
- 每通道采样率 96kHz → 48kHz (循环率减半, 但通道数 1→4)
- DAC 输出 TDM 混音 (1 个 DAC 物理输出 192kHz 切换)

## 下一步
- v1.4: 加波形选择 (sine/square/saw/triangle, 复用 wavetable ROM 高位, +0 IC)
- 加硬件包络发生器 (CPU 减负)

---
生成时间: {datetime.now().isoformat(timespec='seconds')}
"""

def main():
    missing = [f for f in INCLUDE if not os.path.exists(f)]
    if missing:
        print(f"WARNING: missing files: {missing}")

    with zipfile.ZipFile(OUT_ZIP, "w", zipfile.ZIP_DEFLATED) as zf:
        # 写 README
        zf.writestr("README.md", README)
        # 添加文件 (按目录结构)
        for f in INCLUDE:
            if os.path.exists(f):
                zf.write(f)
                print(f"  + {f}")
            else:
                print(f"  ! missing: {f}")

    size = os.path.getsize(OUT_ZIP)
    print(f"\nGenerated: {OUT_ZIP}")
    print(f"Size: {size:,} bytes ({size/1024:.1f} KB)")

if __name__ == "__main__":
    main()
