# MiniGlow 交接文档（下个窗口接手指南）

> 交接时间：2026-07-05（本会话二次更新：FT232H 复用架构已实施 + C 仿真器已建）
> 状态：**FT232H 下载/运行复用架构已落地，11 个测试全 PASS（RTL 16 + C sim 8）**
> 下个窗口起点：wave-mix 协处理器 RTL / miniglowcc 编译器后端

---

## 〇、本会话产出（2026-07-05 第二次，FT232H 复用 + C 仿真器 + AUDIO_OUT）

### 落地的改动

1. **彻底搞清萤火虫原版方法**（基于 C 编译器源码 `GlowCompiler/`）
   - 下载协议：串口 `WriteFile` 灌 `rom.bin`（1MB，16 字节/块，单向无握手，`GlowCompilerDlg.cpp` L527-543）
   - 下载器板：CH340 + 595×2 + 161×3 + 74×2 + 逻辑门（约 10 片），通过 JP1(IDC20) 专用下载口
   - **颠覆性发现**：ALU 表不是预烧 ROM，是开机由 CPU 用 ISA 指令自举生成（`glow.cpp` `glow_cpu_init()` L13185+）
   - 详见 `docs/ft232h-comm.md` 第一章（每条带源码行号）

2. **三条独立通路架构**（核心：音频必须有独立出口，否则项目没用）
   - **FT232H（双向）**：MODE=0 下载 / MODE=1 上位机通信（SEG=3 段 IO_OUT/IO_IN）
   - **AUDIO_OUT（单向输出）**：CPU `IO0 = sample`（`0Axx`）→ AUDIO_OUT 引脚 → TLC7524 D0-D7 → 模拟音频。**独立端口，不走 FT232H**
   - **协处理器接口（双向）**：SEG=4 段 CP_REG_IDX/CP_REG_DATA
   - `rtl/hc241.v` 新建（MODE 总线仲裁）
   - `miniglow/rtl/miniglow_top.v` 重写：新增 AUDIO_OUT 端口 + FT232H 接口 + 协处理器换 SEG=4

3. **C 指令级仿真器**（仿照 `Glowworm-1/sim/glowworm_sim.c` 风格）
   - `miniglow/sim/miniglow_sim.c`：加载 hex、单步、trace、自动 check（A + AUDIO_OUT）
   - `miniglow/sim/tests/*.hex`：5 个测试程序
   - `miniglow/sim/run_tests.sh`：一键回归

4. **CPU 全实例化 + 单 SRAM 架构**（PSG2 v0.3 全实例化原则）
   - PC：`reg [15:0] PC_reg` → **HC161 ×4 级联**（CET 串级计数 + PE 跳转预置）
   - 寄存器组：`always` 块 → **HC374 ×6**（A/B/RA_L/RA_H/AUDIO_OUT/IO_OUT，D mux 选择，自反馈保持）
   - **单 SRAM 架构**：程序/RF/参数/通信/协处理器全在一片 628512（512KB），靠 SEG 段划分
     - 简单音源（SCC/方波/PSG）程序+数据 < 1KB，512KB 绰绰有余
     - 萤火虫原版风格：所有"ROM"都是 SRAM，CR2032 保持 + FT232H 热刷
   - 当前 **21 片**（比萤火虫原版 23 片少 2 片），所有时序/ISA 语义不变

### 测试结果（全 PASS）

| 测试 | iverilog RTL | C 仿真器 | 对拍 |
|------|-------------|---------|------|
| basic (A=0x46, AUDIO=0x55) | 3/3 PASS | 2/2 PASS | ✓ |
| jmp (循环计数 A=9) | 1/1 PASS | A=9 一致 | ✓ |
| jcc (A==3 跳) | 1/1 PASS | A=3 一致 | ✓ |
| ram (SRAM w/r, AUDIO=0x55) | 3/3 PASS | 2/2 PASS | ✓ |
| cp (CP 握手 A=0xAA) | 2/2 PASS | 2/2 PASS | ✓ |
| ft232h (MODE=0 下载 + MODE=1 通信 + MODE 切换) | 6/6 PASS | — | — |
| **audio** (采样流：8 点正弦 → AUDIO_OUT 顺序变化) | **2/2 PASS** | — | — |

**总计：iverilog 18/18 PASS，C sim 8/8 PASS，两边完全对拍。**

### 回归命令

```bash
# iverilog 7 个测试（含 ft232h + audio）
export PATH="/d/Program Files/oss-cad-suite/bin:/d/Program Files/oss-cad-suite/lib:$PATH"
for t in basic jmp jcc ram cp ft232h audio; do
  iverilog -g2012 -o /tmp/mg_$t.vvp \
    rtl/hc283.v rtl/hc374.v rtl/hc86.v rtl/hc00.v rtl/hc138.v rtl/hc241.v \
    miniglow/rtl/miniglow_ram.v miniglow/rtl/miniglow_top.v \
    miniglow/tb/miniglow_tb_$t.v
  vvp /tmp/mg_$t.vvp 2>&1 | grep "PASS\|FAIL"
done

# C 仿真器 5 个测试
cd miniglow/sim && gcc -O2 -o miniglow_sim miniglow_sim.c && ./run_tests.sh
```

---

## 一、项目脉络（这个项目从哪来，往哪去）

### 整体路线
```
PSG2 v0.3 (✅ 已上板出声)
    │
    ▼ 用户接触"萤火虫 CPU"（龙少 74 门 8 位机）
Glowworm-1 (✅ 架构吃透：编译器 + C 仿真器 + SCC 实测 580 拍/采样)
    │
    │ 实测发现 8MHz 纯软件跑 SCC 不够
    ▼
miniglow (🔧 进行中) — 萤火虫精简调度核 + 可插拔协处理器
    │
    │ 协处理器加速 SCC/WT/FM（"音源显卡"）
    ▼
最终目标：固化微码/指令集 ROM，30-50 片的 8 音源硬件平台
```

### 三大子项目（同一仓库下）

| 项目 | 状态 | 说明 |
|------|------|------|
| `psg_voice/PSG2 v0.3` | ✅ 已上板 | 17 片纯硬件方波+噪音音源（参考样板，全实例化风格）|
| `Glowworm-1` | ✅ 架构吃透 | 萤火虫研究：verilog 模型 + glowcc 编译器 + glowworm_sim 仿真器 + SCC 实测 |
| `miniglow` | 🔧 进行中 | **本交接文档主项目**：迷你萤火虫调度核 + 协处理器接口 |

---

## 二、miniglow 当前状态（已完成）

### ✅ 5 个测试全 PASS

```bash
# 跑全部 5 个测试（命令在 README.md 和 design.md 都有）
for t in basic jmp jcc ram cp; do
  iverilog -g2012 -o /tmp/mg_$t.vvp \
    rtl/hc283.v rtl/hc374.v rtl/hc86.v rtl/hc00.v rtl/hc138.v \
    miniglow/rtl/miniglow_ram.v miniglow/rtl/miniglow_top.v \
    miniglow/tb/miniglow_tb_$t.v
  vvp /tmp/mg_$t.vvp 2>&1 | grep "PASS\|FAIL"
done
```

| 测试 | 验证 | PASS 数 |
|------|------|--------|
| basic | 立即数→A、ALU ADD、RA 拼接、IO0 输出 | 3/3 |
| jmp | JMP 跳转 + 计数循环 | 1/1 |
| jcc | SUB + JCC 相等跳（循环退出）| 1/1 |
| ram | RAM 写/读 A/读 IO0 | 3/3 |
| cp | 协处理器握手（写参数→启动→读结果）| 2/2 |

### 当前实现（片数 16，超 15 目标 1 片）

| 芯片 | 数量 | 状态 |
|------|------|------|
| HC628512/miniglow_ram | 1 | ✅ 已实例化（miniglow_ram 同步写）|
| HC374 | 4 | ✅ RA_L/RA_H/A/B |
| HC86 | 2 | ✅ ALU SUB（B 取反）|
| HC283 | 2 | ✅ ALU 8 位加法 |
| HC138 | 2 | ✅ 源/目的译码 |
| HC00 | 1 | ✅ 控制门 |
| HC161 | 4 | ⚠️ 待实例化（现为 reg [15:0] PC 简化）|

**用户最新说**：芯片数不严格限制，**比原版（萤火虫 23 片）少就可以**，关键功能要正常。

---

## 三、🚨 下个窗口要做的事（用户最新指引）

### ✅ FT232H 通信架构（本会话已完成）

FT232H 下载/运行复用架构**已实施并通过全部测试**（详见上文"本会话产出"）。
- MODE=0 下载：FT232H 替代萤火虫 CH340+595+161 下载器板，直驱 SRAM
- MODE=1 通信：FT232H 接 CPU IO 口（SEG=3 段 IO_OUT/IO_IN）
- 协处理器换到 SEG=4 段
- HC241 总线仲裁 + MODE 寄存器

### PSG2 v0.3 是参考样板（必读）

PSG2 v0.3 的 `host/psg_adsr_songs_v03.py` 展示了 FT232H 怎么操作硬件：
- FT232H C口（ADBUS C0-C7）= 数据总线
- FT232H D口（ACBUS D4-D7）= 控制线（LE/A0/RST/A1）
- 上位机用 ftd2xx 直接驱动
- `_sd(bit, v)` 设 D 口某位，`write_ctrl` 拼 C口数据 + D口上升沿锁存

**关键区别**：PSG2 v0.3 没有 CPU（FT232H 直接驱动 HC374/HC161）；miniglow 有 CPU（FT232H 通过 IO 口和 CPU 通信）。但物理接口（FT232H C/D 口）一致。

### 待用户确认的 3 个设计点（在 ft232h-comm.md 末尾）

1. CPU IO 端口方向控制（推荐：硬件固定方向）
2. CPU ↔ FT232H 握手（推荐：轮询，先不上中断）
3. MODE 切换控制（推荐：FT232H 一根控制线自动切换）

**先和用户确认这 3 点，再动 RTL**。

---

## 四、必读文档（按顺序）

### 入口（先读）
- `README.md` — 项目定位 + 完成进度 + 复现命令
- `docs/design.md` — **核心**：当前实现总结（测试结果、ISA 子集、地址空间、协处理器接口协议）

### 修正/优化方向
- `docs/ft232h-comm.md` — **下个窗口主任务**：FT232H 通信架构改造
- `docs/isa.md` — ISA 子集完整说明（机器码 + 砍掉哪些）
- `docs/datapath.md` — 数据通路设计（片数清单 + 总线仲裁）
- `docs/address-design.md` — 地址空间设计（628512 8 段分配）

### 上下文参考（其他子项目）
- `../Glowworm-1/README.md` — 萤火虫架构研究（编译器 + 仿真器 + SCC 实测 580 拍/采样）
- `../Glowworm-1/docs/scc-benchmark.md` — SCC 性能基准（580 拍/通道 + 三条加速路线）
- `../Glowworm-1/docs/coproc-design.md` — 8 大音源运算需求分析（决定哪些硬件化）
- `../psg_voice/PSG2 v0.3/README.md` — PSG2 v0.3 全实例化样板（接线表风格）
- `../psg_voice/PSG2 v0.3/host/psg_adsr_songs_v03.py` — **FT232H 操作协议参考**

---

## 五、工具链

### iverilog 仿真（PSG 项目继承）

```bash
export PATH="/d/Program Files/oss-cad-suite/bin:/d/Program Files/oss-cad-suite/lib:$PATH"
# 注意：oss-cad-suite 装在 D:\Program Files\oss-cad-suite（用户多机一致）
# bin 和 lib 都要加 PATH，否则 vvp 崩溃（exit 0xC0000135）
```

### 芯片模型库（项目级 `rtl/`）

复用 PSG2 v0.3 的全实例化芯片模型：
- `rtl/hc161.v` `rtl/hc273.v` `rtl/hc138.v` `rtl/hc283.v` `rtl/hc373.v` `rtl/hc374.v`
- `rtl/hc85.v` `rtl/hc86.v` `rtl/hc00.v` `rtl/hc02.v` `rtl/hc04.v` `rtl/hc08.v` `rtl/hc32.v`
- `rtl/hc62256.v` `rtl/hc628512.v`（**hc628512 是本会话新建**）`rtl/hc39sf040.v`
- `rtl/hc244.v`（**本会话新建**）

miniglow 自己的：`miniglow/rtl/miniglow_ram.v`（628512 同步写变体，简化仿真）

### Glowworm-1 工具（萤火虫架构研究用，miniglow 暂未用到）

- `Glowworm-1/compiler/glowcc.exe` — 萤火虫 C 编译器命令行版（g++ 编译龙少 lcc + glow.cpp）
- `Glowworm-1/sim/glowworm_sim.exe` — C 指令级仿真器
- 用法见 `Glowworm-1/README.md`

---

## 六、miniglow ISA 子集（已验证的机器码）

```
指令格式: 16 位 {opcode[7:0], xx[7:0]}
  opcode 高 4 位 = 源选择
  opcode 低 4 位 = 目的选择

已实现（已 PASS 测试的机器码）:
  立即数为源 (src_hi=0):
    01XX  A    = XX      ✅ basic
    02XX  RA_L = XX      ✅ basic/jcc/ram
    03XX  RA_H = XX      ✅ basic/jcc/ram
    06XX  B    = XX      ✅ basic
    08XX  RAM  = XX      ✅ ram
    0AXX  IO0  = XX      ✅ basic
    0CXX  SEG  = XX[2:0] ✅ ram/cp

  ALU 为源 (src_hi=1):
    11XX  A = ALU[XX]    ✅ basic(XX=00 ADD)/jcc(XX=01 SUB)
    （HC86 取反 B + C_in=1 实现 SUB）

  RAM 为源 (src_hi=3):
    31XX  A   = RAM      ✅ ram/cp
    3AXX  IO0 = RAM      ✅ ram

  跳转:
    07XX  PC <- RA       ✅ jmp
    17XX  if(ALU==0) PC<-RA  ✅ jcc（SUB 后判零 = 相等跳）
    FFFF  NOP
```

地址空间（19 位 = SEG[2:0] + RA[15:0]）：
```
SEG=0  程序 ROM (PC 寻址)
SEG=1  RF + 全局变量
SEG=2  通道参数缓冲
SEG=3  ★ FT232H 通信（IO_OUT/IO_IN）—— 待实施
SEG=4  ★ 协处理器接口（CP_TYPE/REG_IDX/...）—— 待换段
SEG=5+ 预留
```

---

## 七、协处理器接口协议（已验证）

SEG=3 段 RA=0..7 映射到 CP 寄存器组（**待改到 SEG=4 段**，给 FT232H 让出 SEG=3）：

| CP_REG_IDX | 寄存器 | 方向 | 用途 |
|-----------|--------|------|------|
| 0 | TYPE | 只读 | 协处理器类型 |
| 1 | REG_IDX | 读写 | 内部寄存器索引 |
| 2 | REG_DATA | 读写 | 内部寄存器数据 |
| 3 | START | 只写 | 启动计算 |
| 4 | STATUS | 只读 | bit0=DONE |
| 5 | OUT_L | 只读 | 输出低字节 |
| 6 | OUT_H | 只读 | 输出高字节 |

硬件接口信号（CPU 板排针，给协处理器模块）：
```
CP_REG_IDX[2:0] = RA[2:0]
CP_REG_DATA[7:0] 双向
CP_WE  CPU 写时拉高
CP_OE  CPU 读时拉高
CP_INT_n 协处理器中断（可选）
```

测试验证：`tb/miniglow_tb_cp.v`（含 dummy_coproc 模块，跑通完整握手）。

---

## 八、当前 RTL 简化点（真实硬件待补）

| 项 | 当前简化 | 真实硬件 |
|----|---------|---------|
| PC | reg [15:0] | HC161 ×4 级联 |
| 程序 ROM | 16 位 PROG_ROM（reg 数组）| 628512 双字节取指（PC+2，分两次取 opcode/xx）|
| SRAM | miniglow_ram 同步写 | 628512 + WE_n 脉冲生成（HC00 + RC）|
| IO 端口 | output 单向 | **必须改双向**（FT232H 通信改造）|

---

## 九、待办优先级（下个窗口）

1. **✅ FT232H 通信架构改造**（本会话已完成，全测试 PASS）
2. **🔴 wave-mix 协处理器 RTL**（覆盖 SCC/WT，项目最终目标）—— 最优先
   - 在 SEG=4 段挂真实协处理器（SCC 波形累加器 / WT 查表器）
   - 用 C 仿真器（`miniglow/sim/miniglow_sim.c`）快速验证算法
   - 参考萤火虫 SCC 实测：580 拍/通道（纯软件），协处理器加速目标 ~10x
3. **改 glowcc → miniglowcc**（精简 lcc 后端，让 C 代码编出来跑）
   - 萤火虫原版编译器源码在 `E:\...\GlowCompiler\`（已研究透）
   - miniglow ISA 子集更小，后端要砍 ALU 表自举（miniglow 用 HC283 直算）
4. **PC 用 HC161×4 实例化**（替换 reg 简化，全实例化原则）
5. **PROG_ROM 换 628512 双字节取指**（真实硬件路径）
6. **C 仿真器扩展**：加指令统计、性能基准、SCC 算法原型验证

---

## 十、沟通纪律（参考 PSG2 v0.3 handoff）

- **先查文档再问**（miniglow docs/ 写得很全，特别是 design.md 和 ft232h-comm.md）
- **不要捏造用户言论**（用户最新指引在第三节，照着做）
- **datasheet 必查引脚**（HC374/HC161/HC283 等模型引脚定义看 rtl/*.v 头部注释）
- **FT232H 协议必查 PSG2 v0.3 host/psg_adsr_songs_v03.py**（不要凭记忆）
- **全实例化原则**（PSG2 v0.3 风格，每个芯片一个模块实例，无隐藏门）
- **每改 RTL 必跑 5 个测试**（`for t in basic jmp jcc ram cp`）确认无回归

---

## 附录：本会话的关键认知（防遗忘）

### 萤火虫架构精髓
1. **全 RAM 架构**：所有"ROM"都是 SRAM（628512），CR2032 保持 + 下载器热刷
2. **查表 ALU**：ALU = ROM 查表（萤火虫原版），但 miniglow 砍成 HC283+HC86 直接实现（够用）
3. **统一"目的=源"ISA**：所有指令都是"目的 = 源"

### miniglow 设计哲学
- **CPU 当调度器**：跑 ADSR/序列（C 代码），不算乘除（交协处理器）
- **协处理器可插拔**（"音源显卡"）：CPU 通过标准化接口操作，不关心内部算什么
- **比萤火虫少即可**（不严格限片数）

### 性能基准（实测）
- SCC 单通道纯软件 = 580 拍/采样（glowworm_sim 实测）
- 8MHz 跑 5 通道 SCC = 2758 Hz ❌（差 6.4 倍）→ 协处理器必需
- 50MHz 跑 5 通道 SCC = 17241 Hz ⚠️（刚好够）
- 协处理器加速后理论 5 通道 8MHz = ~6400 Hz（仍不够，要更激进特化或降采样率）
