# STC 软件镜像移植路线

> 整理时间：2026-07-05
> 来源：`D:\working\vscode-projects\STC_Chiptune\STC32G144K246`
> 这是一整套在 STC32G144 嵌入式芯片上**实测出声**的音源核心，作为 Glowworm-1 的算法权威参考

## 一、为什么以 STC 代码为参考

萤火虫要跑 SCC/YM2413 等音源算法，**算法本身已经被 STC_Chiptune 在真实硬件上验证过出声**。这些 .c 文件不是教科书伪代码，是 STC32G144 上跑过、听过、调过的实现。

把 STC 的算法"翻译"到萤火虫：
- 数据类型差异（STC `int=16位` vs 萤火虫 `int=32位`）需要适配，但**算法逻辑 100% 保留**
- 性能差异是关键——STC32G144 是 32 位 MCU 单周期 32 位运算，萤火虫是 8 位机要序列化，**同样的 C 代码在两者上开销天差地别**

## 二、STC_Chiptune 的音源核心清单

| 文件 | 算法 | 行数 | 用途 |
|------|------|------|------|
| **scc.c** | SCC (K051649) | 110 | ⭐ 已移植到 Glowworm-1（5 通道波形表混音）|
| sn76489.c | SN76489 PSG | 165 | 与 PSG v0.3 同源（LFSR 噪音参考）|
| ay8910.c | AY-3-8910 | 229 | design.md 8.5 节频率精度对比的参照 |
| ym2413.c | YM2413 OPLL | — | FM 音源（项目远期目标）|
| fm.c | FM 通用 | 19826 | FM 合成 |
| nes.c | NES APU | — | 2A03 音源 |
| gb.c | Game Boy APU | 16217 | LR35902 音源 |
| saa1099.c | SAA1099 | — | 飞利浦音源 |
| brr.c | BRR (ADPCM) | 11126 | SNES 的 ADPCM 解码 |
| adpcm.c | ADPCM | 17724 | YM2610 ADPCM |
| wt.c | Wave Table | 469 | 通用波形表合成（SCC 的泛化）|

## 三、SCC 移植要点（已完成的 scc.c → Glowworm-1）

### 类型适配

STC 的 `types.h`：
```c
typedef unsigned int   u16;   // STC32G int = 16 位
typedef unsigned long  u32;   // long = 32 位
```

萤火虫的 `sw/scc_stc/glow_types.h`：
```c
typedef unsigned short u16;   // 萤火虫 short = 2 字节（不能直接用 int！）
typedef unsigned int   u32;   // int = 4 字节（与 GlowTypedef.h 一致）
```

**关键差异**：STC 的 `u16` 是 `unsigned int`（16位），直接搬到萤火虫会变成 32 位。必须改成 `unsigned short`，否则 `s16 _tmp` 的 16 位饱和语义会破坏。

### 算法保留 100%

`SCC_MIX_CH` 宏（每个采样执行 5 次，性能热点）：
```c
scc_cnt[ch] += scc_step_val[ch];                    // 32 位相位累加
u8 _offs = (u8)(scc_cnt[ch] >> 16) & 0x1F;          // 取波形地址
u8 _b = scc_wav[ch][_offs];                          // 查表
s16 _tmp;
if (_b >= 128)                                       // 补码扩展
    _tmp = -(((s16)(256 - (u16)_b) * (u16)_vol) >> 4);
else
    _tmp = ((s16)(u16)_b * (u16)_vol) >> 4;
mix += _tmp;                                         // 16 位混音累加
```

这段一个字没改，是 Glowworm-1 性能基准（580 拍/采样）和 SCC 专用指令设计的依据。

### 移植产物

- `sw/scc_stc/scc.c` —— 萤火虫版 SCC 核心（仅改 include + 类型）
- `sw/scc_stc/glow_types.h` —— 类型适配
- `sw/scc_stc/main.c` —— 5 通道完整测试（函数调用约定修复后可跑）
- `sw/scc1ch/main_unrolled.c` —— 单通道手动展开基准（**已实测 580 拍**）

## 四、其他音源的移植展望

按性能从易到难估：

| 音源 | 复杂度 | 移植难度 | 备注 |
|------|-------|---------|------|
| SN76489 | 低 | 易 | LFSR 噪音 + 方波，PSG v0.3 已有硬件版参考 |
| AY8910 | 中 | 易 | 3 通道方波 + 噪音 + 包络 |
| **SCC** | **中** | **中** | **当前主攻**，5 通道波形表 |
| NES APU | 中 | 中 | 2A03 方波+三角+噪音+DPCM |
| GB APU | 中高 | 中 | 4 通道立体声 |
| SAA1099 | 中 | 中 | 6 通道方波+噪音 |
| YM2413 | 高 | 难 | FM 合成（相位调制，运算量大）|
| BRR/ADPCM | 高 | 难 | ADPCM 解码 |

## 五、意义

STC 这套代码是 Glowworm-1 的**算法基准**：
- 不需要重新发明算法，照搬即可
- 性能差异是核心研究点（同样 C 代码，STC 32 位 vs 萤火虫 8 位开销对比）
- 特化指令集的设计目标是"让 STC 的 C 代码在萤火虫上跑得够快"，不是"重新设计算法"
