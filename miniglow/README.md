# MiniGlow — 迷你萤火虫调度核（通用音源主板）

> 萤火虫 1 号架构的精简版，**通用音源主板**——CPU 是固定基础，协处理器可换/可加（模块化）。
> 全实例化设计，杜绝隐藏门和抽象 verilog（PSG v0.3 同风格）。

## 🚨 下个窗口先读 [`docs/HANDOFF.md`](docs/HANDOFF.md)

交接文档（含本会话所有进展 + 下个窗口主任务：FT232H 通信架构改造）。

## 项目定位

### 核心理念：CPU + 可插拔协处理器（"音源显卡"）

```
迷你萤火虫 CPU（固定基础，~14 片）
    │
    │ 标准化协处理器接口（排针）
    ▼
┌──────────────┬──────────────┬──────────────┐
│ wave-mix 协  │ PSG 计数器   │ FM op-chain  │  ← 可选/可换模块
│ 处器（SCC/WT）│ 协处理器     │ 协处理器      │
└──────────────┴──────────────┴──────────────┘
```

**关键**：CPU 通过标准接口（CP_TYPE/REG/START/STATUS/OUT 寄存器组）和协处理器通信，**CPU 不关心协处理器内部算什么**——只管写参数、启动、读结果。换个协处理器（SCC→WT→FM）只是 CP_TYPE 变了，CPU 程序结构不变。

这就像 PC 的 GPU——CPU 写命令寄存器，GPU 自己算渲染。

### 为什么做迷你版（不是完整萤火虫）

完整萤火虫 23 片，但当作"通用音源主板的调度器"时大部分能力用不上：
- ❌ A0/A1/A2（24 位数据 RAM 寻址）—— 用 SEG+RA 替代
- ❌ long long / double —— ADSR/序列用整数运算
- ❌ IO1 —— 一个 IO 口够
- ❌ 完整 25 种 ALU（MUL/DIV 等）—— 乘除全交协处理器
- ❌ 查表 ALU ROM —— ALU 用 HC283+HC85 直接实现更省

砍掉这些 → **~14 片核心 IC**，给协处理器让出预算。

### 设计依据

- **架构基础**：萤火虫 1 号（龙少已验证，跑通 NES/3D/UI）
- **ISA 文档**：`Glowworm-1/docs/isa.md`（完整版）+ 本目录 `docs/isa.md`（精简版）
- **设计哲学**：参考 PSG v0.3 的全实例化风格（hc161/hc273/hc138 等真实芯片模型，无隐藏门）

## 文件结构

```
miniglow/
├── README.md               # 本文件
├── docs/
│   └── isa.md              # 迷你 ISA（精简指令集 + 机器码编码）
├── rtl/
│   └── miniglow_top.v      # CPU 顶层（全实例化，待设计）
└── tb/
    └── (测试平台，待设计)
```

## 复用资源

### 芯片模型库（项目级 `rtl/`）

PSG v0.3 已建好的全实例化芯片模型，miniglow 直接复用：

| 模型 | 用途 | 状态 |
|------|------|------|
| hc161 | 4 位计数器（PC、累加器）| ✅ |
| hc273 | 8 位 D 触发器（A、RA、IR）| ✅ |
| hc138 | 3-8 译码器（指令译码）| ✅ |
| hc283 | 4 位加法器（ALU）| ✅ |
| hc373 | 透明锁存器 | ✅ |
| hc374 | D 触发器 | ✅ |
| hc85 | 4 位比较器（条件跳转）| ✅ |
| hc00/02/04/08/32 | 基本门 | ✅ |
| hc62256 | 32K×8 SRAM（数据/RF）| ✅ |
| hc39sf040 | 512K×8 Flash ROM | ✅ |
| hc244 | 8 三态缓冲（总线驱动）| ❌ 待补 |
| hc628512 | 512K×8 SRAM（程序 ROM）| ❌ 待补（或用 39sf040）|

### 工具链

- iverilog 仿真：`/d/Program Files/oss-cad-suite/bin`（与 PSG 同）
- glowcc 编译器：`Glowworm-1/compiler/glowcc.exe`（待适配迷你 ISA）

## 设计原则（PSG v0.3 同款）

1. **全实例化**：RTL 直接实例化真实 74 芯片模型，不写抽象行为级
2. **无隐藏门**：每个门都有用途，编译器/综合器不替我们决定用几片芯片
3. **接线表逐脚标注**：参考 PSG2 v0.3 的 `wiring-table.md`，每个网络的每个芯片引脚都查 datasheet
4. **人脑做架构，AI 做验证**：架构决策由人定，AI 负责建模 + 仿真 + 接线表

## 当前进度

### ✅ 已完成（5+1 测试全 PASS）

- **ISA 子集 + 数据通路设计**（`docs/isa.md`, `docs/datapath.md`）
- **CPU RTL 全实例化**（`rtl/miniglow_top.v`，12 片芯片已实例化）
- **CPU 核心 5 测试 PASS**：
  - basic（立即数+ALU ADD+RA+IO0）
  - jmp（JMP 跳转+循环）
  - jcc（SUB+JCC 相等跳）
  - ram（RAM 写/读 A/读 IO0）
  - cp（**协处理器握手完整：写参数→启动→读结果**）
- **协处理器接口**（SEG=3 段内存映射 + CP_REG_IDX/DATA/WE/OE 标准排针协议）

详见 `docs/design.md`。

### 🔬 进行中（按优先级）

1. **片数优化到 15**（当前 16 片，HC138 砍 1 或 PC 用 12 位）
2. **PC 用 HC161×4 实例化**（现为 reg 简化）
3. **PROG_ROM 换 628512 双字节取指**（现为 16 位 ROM 简化）
4. **wave-mix 协处理器 RTL**（覆盖 SCC/WT）
5. **改 glowcc → miniglowcc**（精简后端）

### 测试复现

```bash
export PATH="/d/Program Files/oss-cad-suite/bin:/d/Program Files/oss-cad-suite/lib:$PATH"
cd D:\working\vscode-projects\74HC-Chiptune
for t in basic jmp jcc ram cp; do
  iverilog -g2012 -o /tmp/mg_$t.vvp \
    rtl/hc283.v rtl/hc374.v rtl/hc86.v rtl/hc00.v rtl/hc138.v \
    miniglow/rtl/miniglow_ram.v miniglow/rtl/miniglow_top.v \
    miniglow/tb/miniglow_tb_$t.v
  echo "=== $t ==="; vvp /tmp/mg_$t.vvp 2>&1 | grep "PASS\|FAIL"
done
```

## 参考

- PSG2 v0.3（全实例化风格的范本）：`psg_voice/PSG2 v0.3/`
- 萤火虫架构研究：`Glowworm-1/docs/`（architecture.md / isa.md / mini-cpu.md）
- 8 大音源运算分析：`Glowworm-1/docs/coproc-design.md`
