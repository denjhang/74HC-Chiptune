# FM6 v0.7 交接文档

> 6 通道 2-op FM 合成器, 查表法, 基于 WSG8 v0.7 TDM 架构
> 创建时间：2026-07-10
> 状态：**单通道 FM 算法 RTL 验证通过 (fm6_core.v + WAV)**

## 一句话定位

在 WSG8 的 TDM NCO 引擎基础上，增加 **conv_vol 二维查表**（sin×env 预计算）和 **ADSR 包络状态机**，实现 2-operator FM 合成。目标：YM2413 OPLL 兼容的 6 旋律通道。

## WSG8 v0.7 的定稿参数 (FM6 继承)

WSG8 逐脚实例化后定稿为 **19 片**（不是最初估计的 16 片）。原因：单 RAM 架构暴露了 3 个物理缺口：

| 缺口 | 新增芯片 | 原因 |
|---|---|---|
| freq 锁存 | +1 HC174 | 单 RAM 一个口, sub0 读 freq 必须锁存到 sub2 |
| 高位地址 mux | +1 HC157 | RAM A4-A7 在 CPU/TDM 模式来源不同 |
| 时序控制 | +1 HC08 | sub2/clk174/cp273/sub0 四个脉冲需要门电路 |

FM6 继承 WSG8 的全部基础设施（接口层 6 片 + TDM 核心 11 片），在此之上增加 FM 专用芯片。

**WSG8 定稿: 19 片, 14.318MHz, 89.5kHz 采样率, 单 62256, 8 通道**

## 和 WSG8 v0.7 的关系

| WSG8 已有的 (19 片) | FM6 复用情况 |
|---|---|
| 接口层 6 片 (LS373×2+HC374+HC04+HC08+HC154) | ✅ 不变 |
| HC161×2 TDM 计数器 | ✅ 改 ÷步数 (6ch×更多步) |
| 62256 单 RAM | ✅ 地址映射改 (加 conv_vol 表 + ADSR 参数) |
| HC283 加法器 | ✅ OP1 NCO + 相位调制加法 |
| HC174 carry/phase | ✅ OP1 |
| HC174 freq 锁存 | ✅ |
| HC273 输出锁存 | ✅ |
| HC157×2 地址 mux | ✅ |
| HC00 + HC08 时序控制 | ✅ (需要更多门, 可能+1 片) |
| TLC7524×2 DAC | ✅ |

| FM6 新增 | 芯片 | 为什么需要 |
|---|---|---|
| conv_vol 查表 | **1 片 62256** | sin(phase) × env_level 预计算, 代替乘法的核心 (2048B) |
| OP2 相位累加 | **1 片 HC283 + 1 片 HC174** | carrier 的 NCO (第 2 个振荡器) |
| 相位调制 | **1 片 HC283** | carrier_phase += modulator_output (FM 的本质) |
| ADSR 包络计数 | **1 片 HC161** | attack/decay 步进计时 (8-bit 溢出触发 level±1) |
| env_level 锁存 | **1 片 HC273** | 当前包络电平 (0-31) → conv_vol 查表地址高位 |
| conv_vol 地址 mux | **1 片 HC157** | 拼地址 {env_level[4:0], phase[5:0]} = 11-bit |
| 时序控制扩展 | **可能 +1 片 HC08** | FM 步数更多, 时序脉冲更多, HC08 门可能不够 |

## FM 算法核心 (从 STC YM2413 提取)

STC 工程已证明 **FM 可以不用硬件乘法器，用查表代替。**

### 每通道每采样运算序列

```
1. OP1 相位累加:  phase_m += freq × mul_m     ← NCO 加法 (WSG8 引擎)
2. OP1 查表:      sin_m = conv_vol[env_m][phase_m]  ← 二维查表 (新)
3. 反馈:          fb_val = sin_m × fb >> 4     ← 移位近似 (HC164)
4. OP2 相位累加:  phase_c += freq               ← 第 2 套 NCO (新)
5. 相位调制:      idx_c = phase_c + sin_m       ← 加法! (新 HC283)
6. OP2 查表:      carrier = conv_vol[env_c][idx_c]  ← 二维查表
7. 输出:          out = carrier × vol >> 2      ← 移位 (TLC7524 级联)
8. ADSR 更新:     env_level 变化 (轮询分摊)
```

### conv_vol 表 (STC 已有完整数据)

```
addr = {env_level[4:0], phase[5:0]}  →  11-bit → 2048 字节
data = sin(phase) × env / 31         →  8-bit 有符号
```

一片 62256 (32KB) 存 16 套正弦变形。数据从 STC `ym2413.c` 的 `ym_conv_vol[32][64]` 直接提取。

### ADSR 包络 (STC 的极简实现)

```
HC161 做 8-bit 计数器: cnt += step
溢出时 (TC): level++ (attack) 或 level-- (decay)
state: 1=attack, 2=decay, 3=sustain, 0=release
```

HC161 计数器溢出触发 env_level 变化, env_level 存在 HC273 里驱动 conv_vol 地址。

## 芯片清单 (design.md 修订: 26 片)

### 复用 WSG8 (18 片, 删 W4 波形 RAM 被 F1 替代)

接口层 6 + TDM 核心 10 (HC161×2, 微码62256, 参数62256, HC283, HC174×2, HC273, HC157×2, HC00, HC08×2) + DAC 2。
(WSG8 的 19 片 - 1 片 W4 波形RAM = 18 片, 因为 FM 不查波形表, 查 conv_vol 表)

### FM 新增 (8 片)

| 位号 | 型号 | 功能 |
|---|---|---|
| F1 | **62256** | conv_vol 查表 RAM (sin×env 预计算, 2048B + 偏移版) |
| F2 | **HC283** | NCO 高位加法 (和 W4 级联做 8/16-bit) |
| F3 | **HC273** | mod_out 锁存 (8-bit, OP1 输出暂存给相位调制) |
| F4 | **HC283** | 相位调制加法 (idx_c + mod_out) |
| F5 | **HC161** | ADSR env_cnt 计数器 (8-bit 溢出计时) |
| F6 | **CD4029×2** | env_level 可逆计数 (OP1+OP2 各 1 套, 算 2 片) |
| F7 | **HC157** | conv_vol 地址 mux (env_level + sin_index 拼 11-bit) |
| F8 | **HC08** | 时序控制扩展 (FM 步数多, 脉冲多) |

### 合计: 18 + 8 = **26 片**

> 全部芯片库存确认 (inventory.md): 62256/HC283/HC174/HC161/HC273/HC157/HC08/CD4029/TLC7524 ✅
> 详见 design.md §9。

## 时序分析

### 每通道 TDM 步数

```
FM 每通道需要:
  OP1 相位累加: 3 子步 (读freq+读acc+加法写回, 同 WSG8)
  OP1 查表:     1 步 (读 conv_vol, 锁存 mod_out)
  反馈移位:     1 步 (HC164 移位 >>4)
  OP2 相位累加: 3 子步
  相位调制:     1 步 (HC283 加法)
  OP2 查表:     1 步 (读 conv_vol, 锁存 carrier)
  输出:         1 步 (锁存 HC273)
  ADSR:         0.2 步 (轮询, 5 通道分摊 1 步)
  = ~9 步/通道

6 通道 × 9 步 × 4 子周期 = 216 clk/采样
14.318MHz / 216 = 66.3kHz 采样率 ← 好!
Nyquist = 33.1kHz → 覆盖全人耳
```

### 优化: 8-bit 加法减少 NCO 步数

```
用 8-bit 加法 (2 片 HC283 并联):
  OP1 相位累加: 2 子步 (读+加法写回, 8-bit 一次)
  OP2 相位累加: 2 子步
  = ~7 步/通道

6 通道 × 7 步 × 4 子周期 = 168 clk/采样
14.318MHz / 168 = 85.2kHz ← 很好!
```

## 和 YM2413 的对比

| | YM2413 (原版) | FM6 v0.7 |
|---|---|---|
| 通道数 | 9 (6旋律+3鼓) | **6 旋律** (鼓用 PSG3 噪音) |
| Operators | 2-op | 2-op |
| 正弦查表 | 硬件正弦 ROM | **conv_vol RAM** (sin×env 预计算) |
| 乘法 | 硬件乘法器 | **查表 + 移位近似** (无乘法器!) |
| 包络 | 硬件 ADSR | HC161 计数器 + HC273 锁存 |
| 音色 | 15 内置 + 1 用户 | RAM 可写 (任意音色参数) |
| 采样率 | ~50kHz | 66-85kHz |
| 芯片 | 1 片 VLSI | **25-27 片 74 系列** |

## 反馈和输出乘法

FM 有两个乘法, 都不需要硬件乘法器:

1. **feedback**: `fb_val = sin_m × fb / 16`
   - fb 只有 8 档 (0-7), 用 HC164 移位 `>>4` 近似

2. **输出音量**: `out = carrier × vol / 4`
   - 用 TLC7524 级联做模拟乘法 (PSG3/WSG8 已验证)

## 待解决问题 (✅ 已在 design.md 解决)

1. [x] conv_vol RAM 写入 → CPU 初始化时写 F1, 2048B 从 ym_conv_vol 提取 (design §4.2/§10)
2. [x] OP1/OP2 共享 TDM 步序列 → 9 步/通道: OP1(步0-3)+OP2(步4-7)+ADSR(步8) (design §3)
3. [x] 相位调制 mod_out 暂存 → F3 HC273 锁存, F4 HC283 做 idx_c+mod_out (design §6)
4. [x] ADSR 状态机 → HC161(env_cnt) + CD4029(env_level 可逆) + 2-bit state (design §7)
5. [x] 频率倍率 → CPU 预乘, 硬件不乘法; fb 只支持 0/1 (design §5.2/§6.2)
6. [x] conv_vol 地址 mux → F7 HC157×2 拼 {env_level[5], sin_index[6]} = 11-bit (design §4.2)

## 参考文件

- **STC YM2413 仿真** (⚠️ 在本仓之外): `E:\working\vscode-projects\STC_Chiptune\STC32G144K246\ym2413.c` + `ym2413.h`
  - ⚠️ STC 工程不在 74HC-Chiptune 仓内, 是平级目录。别在本仓 find, 直接走绝对路径。
    路径已记入 CLAUDE.md 第四节"目录结构"。
- conv_vol 表: ym2413.c 的 `ym_conv_vol[32][64]` (2048 字节, 直接提取)
- 包络逻辑: ym2413.c 的 `ym_update_env()` + `ym_rate_table[16]`
- WSG8 v0.7 架构: `psg_voice/WSG8 v0.7/docs/design.md` + `wiring-table-core.md`
- PSG3 v0.5 总线接口: `psg_voice/PSG3 v0.5/docs/wiring-table-bus.md`
- 库存表: `psg_voice/PSG3 v0.5/docs/inventory.md`

## 待实现 (单通道 RTL 验证通过, 下一步)

1. [x] design.md (详细架构 + FM TDM 步序列 + conv_vol 地址方案 + ADSR + 6 问题方案)
2. [x] conv_vol hex 生成 (从 STC ym_conv_vol 提取 2048B + 偏移版)
3. [x] RTL: fm6_core.v (单通道 2-op FM, 实例化 hc283 做 NCO 加法器)
4. [x] tb: fm6_note_tb.v 单通道 FM 音符验证 + WAV 输出
5. [x] 仿真验证: 440Hz 载波正确, FM 调制产生边带 (880Hz), 过零频率 437.6Hz ≈ 440Hz
6. [ ] **6 通道 TDM 分时** (fm6_core.v 扩展, HCNT ÷216)
7. [ ] ADSR 包络状态机 RTL (HC161+CD4029)
8. [ ] 反馈 fb (第一版只 fb=0/1)
9. [ ] 接线表 (26 片逐脚, 接口层 + 核心层 + FM 层分开)
10. [ ] 上板验证
