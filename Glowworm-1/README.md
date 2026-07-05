# Glowworm-1 — 萤火虫架构研究与 SCC 专用化

> 基于"龙少"萤火虫 1 号（74 门电路 8 位 CPU）的查表架构精髓，特化 SCC/YM2413 专用音源指令集的子项目。
> 不是复刻——是吃透精髓 → 设计专用架构 → 最终固化微码/指令集 ROM。

## 🔑 核心结论（2026-07-05）

- **萤火虫架构已吃透**：verilog 模型（5 项 PASS）+ C 仿真器（端到端跑通 glowcc 输出）+ 命令行编译器跑通
- **SCC 性能实测**：单通道混音 = **580 拍/采样**；8 MHz 跑 5 通道 SCC **不够**（差 6.4 倍），50 MHz 刚好够
- **纯软件很难**——580 拍里乘法 + 32 位运算占大头，8 位序列化是根本瓶颈。出路有两条：
  - **改指令集**：加专用相位累加/波形查表/乘法指令（路线 B）
  - **借助硬件 ALU**：加 74283 并行加法器 / 74181 / 乘法 ROM，CPU 当调度器（路线 C/D）
  - 与 PSG v0.3 同哲学：关键运算交专用硬件
- 详见 [docs/scc-benchmark.md](docs/scc-benchmark.md)

## 项目定位

### 萤火虫架构精髓（要继承的）
1. **全 RAM 架构**：所有"ROM"都是 SRAM（程序/ALU表/数据），靠 CR2032 保持 + 下载器热刷
2. **查表 ALU**：ALU = ROM 查表，地址 = {A,B}，输出 16 位（低 8 位结果 + 高 8 位标志）
3. **统一"目的=源"ISA**：所有指令都是"目的寄存器 = 源寄存器"，机器码高字节选源、低字节是立即数/ALU 模式号
4. **RF 是 RA 寻址的 SRAM**：RF 寄存器堆不是寄存器数组，是 256B SRAM 的不同地址段

### 本项目目标（不照搬，要超越）
| 阶段 | 内容 | 状态 |
|------|------|------|
| **1. 理解架构** | 从编译器/指令集/示例程序反推 + verilog 仿真验证 | ✅ 完成（5 项 PASS）|
| **2. 设计专用架构** | 砍通用 CPU 不需要的部件，加 SCC 专用指令 | 进行中 |
| **3. 固化** | 把微码 ROM + 指令集 ROM 真正固化，芯片数最小化 | 待 |

### 与现有萤火虫硬件的关系
- 龙少直插版 8MHz（已购）+ 自做贴片版 50MHz（在制）→ 用作 SCC 软件适配平台（**另开项目**）
- **本项目**专注架构设计与仿真验证，不焊硬件

## 文档导航

### 核心（按阅读顺序）
- [docs/architecture.md](docs/architecture.md) — **架构深度分析**（软件栈反推，核心文档）
- [docs/isa.md](docs/isa.md) — 指令集权威定义（含完整机器码表）
- [docs/simulation.md](docs/simulation.md) — 仿真模型 + C 仿真器 + 端到端验证
- [docs/scc-benchmark.md](docs/scc-benchmark.md) — ⭐ **SCC 性能基准**（580 拍/采样，主频适配性结论）
- [docs/stc-port.md](docs/stc-port.md) — STC 软件镜像移植路线（SCC 算法来源）

### 参考
- [docs/hardware.md](docs/hardware.md) — 萤火虫硬件实现（BOM 反推，23 片 IC）
- [docs/toolchain.md](docs/toolchain.md) — oss-cad-suite + mingw 工具链部署
- [docs/e2e-issues.md](docs/e2e-issues.md) — verilog 端到端暴露的 ISA 理解偏差（已修，留作记录）

### 原始资料归档
- `docs/ref/` — BOM、系统结构图（萤火虫官方资料副本）
- `docs/sw-stack/` — GlowTypedef.h、cpuio.h（萤火虫软件栈参考头文件）

## 代码结构

```
Glowworm-1/
├── README.md                    # 本文件
├── docs/                        # 所有文档
│   ├── architecture.md          # ⭐ 架构深度分析（先读这个）
│   ├── isa.md                   # 指令集
│   ├── simulation.md            # 仿真与测试
│   ├── hardware.md              # 硬件实现
│   ├── toolchain.md             # 工具链
│   ├── ref/                     # 原始资料归档
│   └── sw-stack/                # 软件栈参考
├── rtl/
│   └── glowworm1.v              # 萤火虫 CPU 行为级 verilog 模型
├── tb/
│   ├── glowworm1_tb_basic.v     # 数据通路测试 ✅
│   ├── glowworm1_tb_jmp.v       # 无条件跳转测试 ✅
│   └── glowworm1_tb_jcc.v       # 条件跳转测试 ✅
├── compiler/                    # ⭐ 萤火虫 C 编译器（命令行版）
│   ├── build.sh                 # 一键编译脚本（bash build.sh）
│   ├── cli_main.cpp             # 命令行入口（替代 MFC GUI）
│   ├── cli_compat.h             # MFC CString shim（让原代码 0 修改编译）
│   ├── pch.h                    # 预编译头（指向 cli_compat）
│   ├── glowcc.exe               # 编译产物（build.sh 生成）
│   └── *.cpp / *.h              # lcc 核心 + 萤火虫后端（龙少原代码）
├── sim/                         # ⭐ C 指令级仿真器
│   ├── glowworm_sim.c           # 仿真器（按真实 ISA 单拍模拟 + 性能统计）
│   ├── glowworm_sim.exe         # 编译产物
│   └── rom.bin                  # 最近一次跑的 ROM
├── sw/                          # 测试 C 程序
│   ├── test1/                   # 空 main（验证编译链路）
│   ├── test2/                   # IO0 = 0x55（验证代码生成）
│   ├── scc_stc/                 # SCC 算法（移植自 STC_Chiptune/scc.c）
│   └── scc1ch/                  # 单通道 SCC 性能基准（手动展开防 lcc 优化）
└── rom/                         # （预留）编译器输出 hex
```

## 编译器用法（命令行版）

```bash
# 1. 构建 glowcc.exe（一次性）
cd Glowworm-1/compiler
bash build.sh

# 2. 编译 C 程序（在 .c 文件所在目录）
cd Glowworm-1/sw/test2
PATH="/d/msys64/mingw64/bin:$PATH" ../../compiler/glowcc.exe main.c
# 输出: rom.bin (二进制 ROM) / asm.txt (反汇编) / error.txt (错误+占用报告)
# 注意：lcc 死代码消除激进，循环若没副作用会被砍（测性能时用 IO0 写入或手动展开）
```

## 仿真器用法（C 指令级）

```bash
cd Glowworm-1/sim
gcc -O2 -o glowworm_sim.exe glowworm_sim.c
./glowworm_sim.exe rom.bin [max_cycles] [-v] [-mark] [-trace start end]
#   -v          打印 opcode 直方图
#   -mark       每次 IO0 变化打印 cycle（性能基准用）
#   -trace s e  打印 cycle [s, e) 的指令 trace
```

## 快速验证

跑全部三个仿真测试（每个应显示 PASS）：

```bash
export PATH="/d/Program Files/oss-cad-suite/bin:/d/Program Files/oss-cad-suite/lib:$PATH"
cd D:\working\vscode-projects\74HC-Chiptune
for tb in basic jmp jcc; do
  iverilog -g2012 -o /tmp/$tb.vvp Glowworm-1/rtl/glowworm1.v Glowworm-1/tb/glowworm1_tb_$tb.v
  echo "=== $tb ==="
  vvp /tmp/$tb.vvp 2>&1 | grep -E "PASS|FAIL"
done
```

## 当前进展（2026-07-05）

### ✅ 已完成

**架构吃透**（编译器 + 指令集 + 示例程序三源交叉验证）
- ISA 全部核心机制在 verilog 模型上验证通过（5 项 PASS）
- 萤火虫 C 编译器命令行版（`compiler/glowcc.exe`）跑通：剥离 MFC GUI，g++ 编译龙少原 lcc + glow.cpp 后端，C → 机器码链路打通
- C 指令级仿真器（`sim/glowworm_sim.c`）跑通真实编译器输出：端到端 2130 拍跑完 `IO0 = 0x55`，**修正了两个关键 ISA 理解偏差**：
  - 跳转目标 A2A1A0 是**字地址**，硬件 PC 字节地址 = A2A1A0 × 2
  - dst=9 (`ALU[XX]=源`) 是"触发 ALU 计算 + 写 RF[RA]"，src 不参与计算

**⭐ SCC 性能基准实测**（核心里程碑）
- 移植 STC_Chiptune 的 scc.c 到萤火虫，用 glowworm_sim 跑真实 ROM 数周期
- **单通道 SCC 混音 = 580 拍/采样**（实测，非估算）
- 主频推算：

  | 主频 | 单通道采样率 | 5 通道采样率 | vs SCC 标准 (17640 Hz) |
  |------|------------|------------|----------------------|
  | 8 MHz | 13793 Hz | **2758 Hz** | ❌ 差 6.4 倍 |
  | 50 MHz | 86206 Hz | **17241 Hz** | ⚠️ 刚好够（无余量）|

- **结论**：8 MHz 纯软件跑 5 通道 SCC 远不够 → **必须特化指令集**（你早就判断，现在有数据）

详见 `docs/scc-benchmark.md`。

### 🔬 进行中
- 看 asm.txt 确认 lcc 对 `u8 * u8` 是否用 MUL_L 单指令（决定乘法特化优先级）
- 三条加速路线评估：纯软件 / 专用指令集 / 硬件 ALU（74283/74181）加速
- 设计专用指令集 ISA 编码 + 硬件 ALU 加速块接入方式（怎么和查表 ALU 共存）

### ⏳ 待办
- 修复函数调用约定（OUTA/OUTB ALU 模式语义）让 scc_render 可调用，测 5 通道全变量
- 在 verilog/C 仿真器里加 SCC 专用指令，测性能提升
- 最终固化微码 ROM + 指令集 ROM

## 参考资源

- 龙少 B 站主页（萤火虫 CPU）：https://www.bilibili.com/video/BV16m4y137Ad/
- 萤火虫官方资料（百度网盘，提取码 7777）：https://pan.baidu.com/s/1n2U553-tAYNSQ06JEb88gA
- 本项目根目录的 PSG v0.3 子项目（音源方向先发项目）
