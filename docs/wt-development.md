# Wavetable (WT) 合成器开发记录

## 项目概述

基于 Arduino Uno Wavetable Synthesis（作者 Keiji Katahira）移植的 WT 合成器核心，参考 STC32G 移植版 `wt.c` 的参数体系。

## WT 合成算法

### 核心公式

```
phase += step                          // 16-bit 相位累加
idx = (phase >> 5) & 0x7F              // 取高 11 位，掩码到 7 位寻址 128 点 ROM
out = wave_rom[idx] * (level+1)        // 波形 × 包络音量
dac = mix >> N                         // 混音输出
```

### 频率步进 (step) 计算

```
step = freq * 8192 / sample_rate
```

- `phase` 为 16-bit，`phase >> 5` 取高 11 位，掩码 7 位得到 0-127 的 ROM 索引
- 13-bit 精度（step 最大 8191），这是频率准确度的关键

#### 常用音符 step 值（sample_rate = 32051Hz）

| 音符 | 频率 (Hz) | step 值 |
|------|-----------|---------|
| C4   | 261.6     | 67      |
| D4   | 293.7     | 75      |
| E4   | 329.6     | 84      |
| F4   | 349.2     | 89      |
| G4   | 392.0     | 100     |
| A4   | 440.0     | 112     |
| B4   | 493.9     | 126     |
| C5   | 523.3     | 134     |

STC32G 版采样率 17640Hz，对应 C4 step = `261.6 * 8192 / 17640 ≈ 121`。

### 波形 ROM

- **128 点**，有符号 8-bit（±31）
- 14 种波形：方波×4、正弦类×8、三角波、锯齿波、GB DMG
- 波形数据来自 STC32G 移植版 `wt.c` 的 `wt_waves[]` 数组
- 正弦波（wave 4）已导出为 `rom/sin_128.hex`

### ADSR 包络

4 状态机：attack → decay → sustain → release

- `level`: 0-31，每个包络周期步进 ±1
- `env_cnt`: 计数器，达到阈值后步进 level
- attack: level 0→满，decay: level 下降，sustain: 保持，release: 衰减到 0

## 仿真验证流程

### 快速验证方案：Behavioral Testbench

不例化 RTL 模块，直接在 testbench 中用行为级描述 WT 算法：

```verilog
// 不需要例化 wt_top，直接在 tb 里写核心逻辑
// 优势：编译快、仿真快、参数灵活
// 劣势：不验证实际 RTL 的时序和接口
```

**性能对比**：
- `wt_fast_tb.v`（behavioral）：16000 采样 ≈ 2s 完成
- `wt_top_tb.v`（例化 RTL）：128000 采样 ≈ 数分钟

### 完整编译/仿真/验证命令

所有命令在项目根目录 `74HC-Chiptune/` 下执行，Git Bash 环境。

```bash
# ---- 环境设置 ----
export PATH="/c/Users/denjhang/iverilog/bin:$PATH"

# ---- 快速行为级 testbench ----
# 编译
iverilog -o tb/wt_fast_tb.vvp tb/wt_fast_tb.v

# 运行仿真（输出 wt_output.csv）
vvp tb/wt_fast_tb.vvp

# ---- RTL 总线接口 testbench ----
# 编译（需要包含 ROM 路径）
iverilog -o tb/wt_top_tb.vvp rtl/wt_top.v tb/wt_top_tb.v

# 运行仿真（输出 wt_output.csv）
vvp tb/wt_top_tb.vvp

# ---- 生成波形 ROM hex 文件 ----
# 从 STC32G wt.c 的 wave 数据导出（只需做一次）
python3 -c "
vals = [0,2,3,5,6,8,9,10,12,13,15,16,17,18,20,21,22,23,24,25,26,27,27,28,29,29,30,30,30,31,31,31,
        31,31,31,31,30,30,30,29,29,28,27,27,26,25,24,23,22,21,20,18,17,16,15,13,12,10,9,8,6,5,3,2,
        0,-2,-3,-5,-6,-8,-9,-10,-12,-13,-15,-16,-17,-18,-20,-21,-22,-23,-24,-25,-26,-27,-27,-28,-29,-29,-30,-30,-30,-31,-31,-31,
        -31,-31,-31,-31,-30,-30,-30,-29,-29,-28,-27,-27,-26,-25,-24,-23,-22,-21,-20,-18,-17,-16,-15,-13,-12,-10,-9,-8,-6,-5,-3,-2]
for v in vals:
    print(f'{v & 0xFF:02X}')
" > rom/sin_128.hex

# ---- 频率验证（Python） ----
python3 -c "
import math
samples = []
with open('wt_output.csv') as f:
    next(f)
    for line in f:
        parts = line.strip().split(',')
        if len(parts)==2:
            v = parts[1].strip()
            if v in ('x','X','z','Z'): samples.append(0)
            else:
                try: samples.append(int(v))
                except: samples.append(0)

sr = 32051
# 零交叉法测频率
seg = samples[500:8000]
crossings = sum(1 for i in range(1,len(seg))
    if (seg[i-1]>=0 and seg[i]<0) or (seg[i-1]<0 and seg[i]>=0))
freq = crossings / 2 / (len(seg)/sr)
print(f'Freq: {freq:.1f} Hz (expect 261.6)')
"

# ---- 转换 WAV ----
python3 csv_to_wav.py wt_output.csv
# 输出: wt_output.wav (8-bit unsigned, 32051Hz, mono)
```

### 验证结果（2026-06-12）

| 项目 | 结果 |
|------|------|
| ch0 C4 (261.6Hz) | 零交叉法 260.7Hz，误差 0.3% |
| ch1 A4 (440Hz) | DFT 确认 440Hz 处强信号 |
| 双通道混音 | DFT 在 261.6Hz 和 440Hz 均有峰值 |
| 包络 attack | 从 0 渐入到满幅，听感类似笛子 |
| 音色 | 纯正弦波 + ADSR → 类似吹笛声 |

## iverilog 常见坑

### 1. `$sin()` 不支持

iverilog 不支持在 `initial` 块中使用 `$sin()` 等数学函数初始化 ROM。

**解决**：用 Python 生成 hex 文件，Verilog 中用 `$readmemh` 加载：
```verilog
initial begin
    $readmemh("rom/sin_128.hex", wave_rom);
end
```

### 2. 拼接位宽不确定

```verilog
// 错误：iverilog 报 "indefinite width"
$signed({1'b0, (env0 + 1)})

// 正确：先扩展到确定位宽
env_ext <= $signed({1'b0, env0}) + 1;
result <= wave_rom[idx] * env_ext;
```

### 3. `$signed()` 输出 `x`

`mix_out` 在第一拍可能为 `x`（寄存器延迟初始化），`$signed()` 会输出字面 `x` 到 CSV。

**解决**：Python 分析时将 `x`/`z` 替换为 0：
```python
v = parts[1].strip()
if v in ('x','X','z','Z'):
    samples.append(0)
```

## 文件清单

| 文件 | 说明 |
|------|------|
| `rtl/wt_top.v` | WT 合成器 RTL（并行总线接口，待更新参数） |
| `tb/wt_fast_tb.v` | 快速行为级 testbench（已验证频率正确） |
| `tb/wt_top_tb.v` | 总线接口 testbench（通过例化 wt_top） |
| `rom/sin_128.hex` | 128 点正弦波 ROM（来自 STC32G wt.c wave 4） |
| `rom/sin_64.hex` | 64 点正弦波 ROM（旧版，已弃用） |
| `csv_to_wav.py` | CSV → WAV 转换脚本 |

## 参考项目

- STC32G 移植版: `D:\working\vscode-projects\STC_Chiptune\STC32G12K128\wt.c`
  - 16 通道，128 点波形表，14 种波形，ADSR 包络
  - **这是频率参数和算法的权威参考**
- Arduino 原版: `D:\working\vscode-projects\Reference_Project\STC-MCU\extracted\ArduinoUno_wavetable_synthesis-master\`
  - Keiji Katahira 的原始实现，单通道
