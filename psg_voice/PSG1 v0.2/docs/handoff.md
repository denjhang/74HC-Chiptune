# PSG1 v0.2 交接文档

> 单音 PSG + 4-bit 音量（TLC7524 衰减器）+ ADSR 包络 + 颤音 + 移调
> 交接时间：2026-07-02
> 状态：**硬件实测出声成功，ADSR+颤音+移调合成器完成**

## 一句话现状

v0.2 在 v0.1（单通道方波）基础上加了 **4-bit 数字音量**（HC374 锁存 + TLC7524 衰减器），去掉了 gate（vol=0 静音替代）。**硬件实测出声成功**：TLC7524 正向接法（REF=方波输入/OUT1=输出/RFB=GND）音量调整生效，上位机 `psg_adsr_songs_v02.py` 实现钢琴风格 ADSR 包络 + period 三角波颤音 + 移调（key 调号/音符级升降/八度）+ 7 首曲目库（ini 可编辑）。（初版误用反接电压模式致噪音+音量失效，已改正。）

## 文件位置

```
psg_voice/PSG1 v0.2/
├── docs/
│   ├── design.md          # 设计文档（架构/地址映射/决策记录）
│   ├── wiring-table.md    # ⭐ 接线表（HC374+TLC7524+HC00改动，全引脚）
│   └── handoff.md         # 本文件
├── rtl/
│   └── psg_voice_v02.v    # 顶层 RTL（含 HC374+TLC7524 行为模型）
├── tb/
│   ├── psg_voice_v02_tb.v # 音量/频率/静音验证（全过）
│   └── psg_v02_debug.v    # tc_hi/reload/toggle 追踪调试
├── host/
│   ├── psg_adsr_songs_v02.py  # ⭐ 最终控制脚本（ADSR+颤音+曲目库+键盘）
│   ├── psg_songs.ini          # 曲目库（简谱文本格式，用户可编辑增删）
│   ├── psg_config.ini         # 用户调参成果（速度/颤音，必提交）
│   └── (psg_env/adsr/ft232h 等为迭代中间产物)
├── Main_2026-07-01.net    # 实际电路 netlist（权威接线依据）
└── tlc7524.docx/pdf       # TLC7524 datasheet 留档
```

项目级共享：
- `rtl/hc374.v` — HC374 模型（v0.2 新建，可复用）
- `rtl/hc373.v hc161.v hc00.v` — v0.1 复用

## 设计要点（速览）

### 相对 v0.1 的改动
| 项 | v0.1 | v0.2 |
|----|------|------|
| 音量 | gate 开关 | **4-bit 数字音量（TLC7524）** |
| gate | HC00 与门 | **去掉**（vol=0 静音替代）|
| 控制信号 | LE/gate/RST | **LE/A0/RST**（D5 从 gate→A0 音量选通）|
| 新增芯片 | — | HC374（音量锁存）+ TLC7524（衰减器）|

### 总线（FT232H 11 根，恒定）
| FT232H | 信号 | 作用 |
|--------|------|------|
| C0-C7 | D0-D7 | 复用数据（写 period 全 8 位 / 写音量低 4 位）|
| D4 | LE | period 写选通 → HC373 |
| D5 | A0 | 音量写选通 → HC374 CP |
| D6 | RST | 复位 |

### 音量映射
`audio_out = toggle_q ? (vol << 4) : 0`（vol 0-15 → 幅度 0-240，对应 0-4.7V）

### 输出链路（R-2R 正向接法，须运放缓冲）
```
toggle_q(0/5V方波) → TLC7524 Pin15/REF(参考输入) → R-2R 衰减 → Pin1/OUT1(输出=5V×D/256)
                   → 耦合电容(隔直) → 运放(缓冲) → 喇叭
```
**接法说明**：REF 接方波（低阻参考源），OUT1 取衰减后输出，RFB(Pin16) 接 GND 补全梯形网络。
OUT1 输出阻抗较高（R-2R 网络），实际推喇叭须加运放缓冲。
TLC7524 引脚（实测 DIP-16）：Pin1=OUT1 / Pin2=OUT2 / Pin3=GND / Pin4-8=DB7-DB3 / Pin9-11=DB2-DB0 / Pin12=CS / Pin13=WR / Pin14=VDD / Pin15=REF / Pin16=RFB。

> ⚠️ **历史教训**：初版误用"反接电压模式"（OUT1=输入/REF=输出/RFB 悬空），实测噪音叠加方波 + 音量失效。
> 根因（datasheet SLAS061D）：①电压模式只保证 OUT1≤2.5V 线性，0/5V 方波超范围；②OUT1/REF 寄生电容随数字码跳变（30↔120pF）致振铃噪音；③RFB 悬空致梯形电流无处泄放。
> 改成正向接法（REF=输入/OUT1=输出/RFB=GND）后音量逻辑恢复。

## 仿真验证结果（全过 ✅）

```
音量衰减: vol=15→240, vol=8→128, vol=4→64, vol=0→0  ✅
静音: vol=0 输出恒 0                                   ✅
频率: A4=440Hz @64kHz 精确                             ✅
总线复用: data 写 period(LE) + 写音量(A0) 时序正确      ✅
```

编译命令（备忘）：
```bash
set PATH=D:\Program Files\oss-cad-suite\bin;D:\Program Files\oss-cad-suite\lib;%PATH%
cd "psg_voice\PSG1 v0.2"
iverilog -g2012 -o tb/psg_voice_v02_tb.vvp ^
  E:\working\vscode-projects\74HC-Chiptune\rtl\hc373.v ^
  E:\working\vscode-projects\74HC-Chiptune\rtl\hc161.v ^
  E:\working\vscode-projects\74HC-Chiptune\rtl\hc00.v ^
  E:\working\vscode-projects\74HC-Chiptune\rtl\hc374.v ^
  rtl\psg_voice_v02.v tb\psg_voice_v02_tb.v
vvp tb/psg_voice_v02_tb.vvp
```

## 已完成

- ✅ **硬件实测出声**：TLC7524 正向接法（REF=方波输入/OUT1=输出/RFB=GND）音量调整生效
- ✅ **FT232H 控制脚本** `host/psg_adsr_songs_v02.py`：
  - 钢琴风格 ADSR 包络（A快/D明显/S低/R快），D/R 随速度缩放
  - 颤音（period 三角波偏移，≤半半音；延迟/频率/幅度均可键盘调）
  - **移调**（ini 层面）：
    - 调号 `key=F` 全曲移调（1=do=F，+5 半音），支持 C/D/E/F/G/A/B 及 #/b
    - 整曲八度 `key=^C`（升八度）/ `key=,C`（降八度）
    - 音符级升降 `5+`（升 sol）/`6-`（降 la），与 key 独立叠加
  - **乐谱实时打印**：播放时逐音 `[token]` 显示，换行与 ini 一致
  - 曲目库外置 `psg_songs.ini`（简谱文本格式，用户可编辑增删）
  - 键盘控制（独立线程中断响应）：n/b 切歌，./, 速度，v 颤音开关，;/' 颤音频率，[/] 颤音幅度，-/= 颤音延迟，q 退出
  - `--song N` 命令行单曲循环
  - 所有参数持久化到 `psg_config.ini`
  - 切歌时 RST 复位 + 音量清零
- ✅ 总线 bug 修复：写 period/音量前先关掉对方选通信号（freq 先 A0=0，volume 先 LE=0），防串扰
- ✅ TLC7524 引脚定义修正（据 datasheet + 实测 net）
- ✅ 音量接线论证（DB4-7 高 4 位最优）

## 待办

### 1. 曲目准确性
- 新加的 3 首（友谊地久天长/铃儿响叮当/粉刷匠）简谱需用户实测校对，不准的在 `psg_songs.ini` 直接改
- 可继续补充曲目（编辑 ini 即可，无需改代码）

### 2. 文档补充
- wiring-table.md 的 U7 输出链路：当前 RFB 接 GND 是简化验证，datasheet Figure 3 标准做法是 RFB 接运放输出（I-V 闭环）。实测若 OUT1 带载不足再加运放。
- 实测后更新 development-log（如 v0.1 那样记录硬件调试过程）

### 3. RTL 同步
- `rtl/psg_voice_v02.v` 的 TLC7524 行为模型注释已改（正向接法），但物理引脚映射以 net 文件为准。如需 RTL 完整反映新接法可进一步细化。

## 下一阶段：LFSR 噪音通道（v0.3 方向，待规划）

v0.2 当前只有方波音调通道（tone）。下一步加**噪音通道**（noise），目标类似 SN76489 的噪声通道：
- **LFSR（线性反馈移位寄存器）** 产生伪随机序列，输出白噪声/周期噪声
- 参考实现：`STC_Chiptune/STC32G144K246/sn76489.c` 的 noise 渲染（16-bit LFSR，taps=0x0009，可设周期）
- 与音调通道独立：噪音有自己的音量寄存器 + 频率（移位时钟分频）
- 混音：tone 输出 + noise 输出 → 求和 → TLC7524（或单独 DAC）
- 待定：硬件 LFSR（HC164+异或门）还是软件 LFSR（FT232H 上位机算）
- 计划明天做，先写进 design.md 规划。

## 关键经验（从 v0.1 带过来的硬件教训）

接 v0.2 硬件时务必注意（v0.1 踩过的坑）：

1. **电平转换必需**：FT232H 3.3V 输出 < 74HC 的 VIH(3.5V)，必须经 LS373 转换。**A0 信号也要过 LS373**（v0.1 的 gate 就是没转换才不响）。
2. **toggle 必须用 HCT74**：HC74 高频翻转失效（v0.1 实测 A6+ 消失），HCT74 才稳。
3. **period 数据走 C0-C7**：FT232H 的 D1/D2 是 MPSSE 的 TDI/TDO，写 0 会被强制拉高，不能用。控制信号走 D4-D6。
4. **每片芯片就近加 0.1μF 去耦电容**，所有 GND 共地。
5. **时钟 64kHz**（v0.1 验证的甜点，覆盖 C3-C8）。

详见 `psg_voice/PSG1 v0.1/docs/development-log.md` 第 10 章"硬件调试实录"（7 个 bug 全记录）。

## 后续版本规划

| 版本 | 内容 | 触发条件 |
|------|------|---------|
| **v0.2**（当前）| 1通道 + 4bit音量 | 仿真过，待硬件实测 |
| **PSG2 v0.3** | 扩展到 **2 通道** | v0.2 硬件验证音量成功后 |
| PSG3+ | 多通道 + HC138 总线复用 + 包络/噪声 | 多通道架构验证后 |

v0.3+ 会引入 HC138 地址译码（A0/A1 → Y0-Y3 选通多寄存器），FT232H 仍 11 根线不变。详见 design.md 的"为多通道铺路"注释。

## Git 状态

```
最近 3 个 commit:
3fb9f6a feat(psg_voice v0.2): RTL + 仿真通过 (1通道方波 + 4bit音量)
a0c561d docs(psg_voice v0.2): 接线表 (HC374音量锁存 + TLC7524衰减器)
f168e12 docs(psg_voice v0.2): 去掉gate, 音量码0静音, 总线变标准 LE/A0/RST
```

v0.2 全部内容已提交。分支 main，单人项目直接提交。
