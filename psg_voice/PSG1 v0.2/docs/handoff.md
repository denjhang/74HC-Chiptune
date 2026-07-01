# PSG1 v0.2 交接文档

> 单音 PSG + 4-bit 音量（TLC7524 衰减器）
> 交接时间：2026-07-01
> 状态：**设计 + 仿真完成，待硬件实测**

## 一句话现状

v0.2 在 v0.1（单通道方波）基础上加了 **4-bit 数字音量**（HC374 锁存 + TLC7524 衰减器），去掉了 gate（vol=0 静音替代）。**RTL 仿真全过，硬件链路物理必然可行（TLC7524 分压 → 耦合电容 → 运放），待实际搭电路验证出声。**

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
└── host/                  # 空，待写控制脚本
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

### 输出链路（电压模式，须运放缓冲）
```
toggle_q(0/5V方波) → TLC7524 Pin1/OUT1(输入) → Pin15/REF(输出=5V×D/256)
                   → 运放(高阻缓冲, 必需, REF输出阻抗高) → 耦合电容(隔直) → 喇叭
```
**运放是必需的**：TLC7524 电压模式下 REF 端输出阻抗高，直推喇叭会被拉低失真。
TLC7524 引脚（实测，DIP-16）：Pin1=OUT1 / Pin2=OUT2 / Pin3=GND / Pin4-8=DB7-DB3 / Pin9-11=DB2-DB0 / Pin12=CS / Pin13=WR / Pin14=VDD / Pin15=REF / Pin16=RFB。电压模式下 RFB(Pin16) 悬空、OUT2(Pin2) 接地。

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

## 待办（按优先级）

### 1. 写 FT232H 控制脚本（host/psg_ft232h_v02.py）⭐
基于 v0.1 的 `psg_voice/PSG1 v0.1/host/psg_ft232h.py` 改：
- D5 从 gate 改成 A0（写音量选通）
- 新增 `set_volume(0-15)` 方法（D0-D3=vol，A0 上升沿）
- 去掉 `set_gate()`（vol=0 即静音）
- 注意：写 period 和写音量共用 D0-D7，要小心别互相干扰（写 period 后 D 口残留值，写音量前要重设 D0-D3）

```python
# 关键改动示意
def set_volume(self, vol):  # vol: 0-15
    self._c = vol & 0x0F        # C口低4位=vol, 高4位=0
    self.dev.write(bytes([0x82, self._c, 0xFF])); time.sleep(2e-3)
    self._sd(BIT_A0, 1); self._sd(BIT_A0, 0)  # A0(D5) 上升沿锁存
```

### 2. 硬件实测
- 按 wiring-table.md 搭电路（在 v0.1 基础上加 HC374 + TLC7524，拆 HC00 的 gate）
- 跑音量渐变测试（vol 0→15 扫一遍，听音量变化）
- 验证 vol=0 真静音（注意 TLC7524 的馈通泄漏，可能不是完全无声）

### 3. 文档补充
- wiring-table.md 补完整输出链路（TLC7524 REF → 电容 → 运放 → 喇叭），现在只写到 REF→喇叭
- 实测后更新 development-log（如 v0.1 那样记录硬件调试）

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
