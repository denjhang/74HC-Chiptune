# 萤火虫 1 号架构深度分析（从软件栈反推）

> 方法：不走硬件原理图，从**编译器后端 + 官方指令集 + 大量示例程序**反推 ISA 实际语义
> 整理时间：2026-07-05
> 这是 Glowworm-1 项目的核心知识资产，所有后续工作（复刻/精简/SCC）都基于本文

## 一、核心认知：萤火虫是"8 位机的体，32 位机的魂"

**最重要的认知（颠覆第一印象）**：

萤火虫在硬件上是 8 位数据通路（8 位寄存器、8 位 ALU ROM 数据宽度低 8 位），但 **C 语言层 `int = 4 字节 / 32 位`**，且**完整支持 IEEE754 双精度浮点**（sin/cos/sqrt/exp/log/pow 全套 fdlibm 移植）。

这不是矛盾——**32 位运算靠 ALU 查表 + 多字节序列化**：编译器把 `int` 加法展开成 4 次字节加法 + 进位传递，每次字节加法是一条 `ALU[ADD] = RF` 指令（查表）。

**这个定位对 SCC 路线极其有利**：SCC 需要的相位累加（24-32 位）、波形查表（8 位）、音量相乘（8×8→16），全都能在 C 层用 `unsigned int`/`unsigned long` 直接写，编译器自动序列化成 ISA 指令。**不需要手写汇编**。

## 二、C 数据模型（来自 GlowTypedef.h，权威）

```c
typedef signed char        int8_t;     // 1 字节
typedef short              int16_t;    // 2 字节
typedef int                int32_t;    // 4 字节   ← int 是 32 位！
typedef long long          int64_t;    // 8 字节
typedef unsigned int       uintptr_t;  // 4 字节   ← 指针 32 位
```

| C 类型 | 字节数 | 备注 |
|--------|--------|------|
| char | 1 | 默认 signed |
| short | 2 | |
| **int** | **4** | **32 位（不是 16/8）**|
| long | 4 | 同 int |
| long long | 8 | 64 位整数 |
| float | 4 | IEEE754 单精度 |
| **double** | **8** | **IEEE754 双精度，DBL_MANT_DIG=53** |
| T* | 4 | 指针 32 位（寻址空间 16MB 够用）|

**含义**：
- 编译器支持完整 C99 类型
- `int` 运算 = 4 次字节 ALU 查表 + 进位链
- `long long` 运算 = 8 次字节 ALU 查表 + 进位链
- double 运算 = fdlibm 软件浮点（数千条指令一次运算）

## 三、硬件访问模型：IO0/IO1 当全局变量

来自 `cpuio.h`，这是 C 代码访问外设的**唯一**方式：

```c
extern unsigned char REGISTER_IO0;  // 编译器/linker 映射到 ISA 的 IO0 端口
extern unsigned char REGISTER_IO1;  // 映射到 IO1
#define IO0 REGISTER_IO0
#define IO1 REGISTER_IO1

// 写：赋值 → 编译器生成 `IO0 = XX`（机器码 0AXX）
IO0 = 0xF8;

// 读：表达式 → 编译器生成 `A = IO0`（机器码 41XX）
unsigned char x = IO0;
```

**IO0 物理布局**（来自 `cpuio.h` 宏定义）：
```
bit0-2: CS（片选，0-7 选 8 个外设之一）
bit3-7: 数据/控制位（双向，每条线既可输入也可输出）
```

**IO0 初始化值 0xF8**：bit0-2=000（CS0 选中）、bit3-7=11111（数据线默认高）。

**影子寄存器模式**（所有示例程序都用）：
```c
unsigned char IO0_STATE;  // C 层影子，记录上次写出的值
// 因为读 IO0 拿到的可能是外部输入，不是上次写出的值
#define IO0_DO_SET_1(data) (IO0_STATE |= (data), IO0 = IO0_STATE)
```

> 这种"硬件端口当全局变量 + 影子寄存器"模式，是 PSG 项目 FT232H 的 C口/D口操作的同类抽象。SCC 在萤火虫上做音频，DAC 接到 IO0/IO1，写采样值就是 `IO0 = sample`。

## 四、性能模型（来自运算速度测试 + ISA 编码）

### CPI 估算

ISA 是 16 位定长指令，每条指令 2 字节。从 `运算速度测试/main.c` 用 `unsigned char a=b+c` 重复测速推断：
- `unsigned char` 加法 ≈ 几条指令（取 b、取 c、ALU 加、存 a）
- 每条指令至少 2 个时钟（取指 + 执行，可能更多）

**50MHz 主频下**（BOM 实测）：
- 若 CPI=4，约 12.5 MIPS
- `unsigned char` 加法 ≈ 4-6 拍 → 约 2-3 MOPS
- `int`（32 位）加法 ≈ 4×字节加法 + 进位链 ≈ 20-30 拍 → 约 0.4-0.6 MOPS
- double 运算 ≈ 数千拍 → 约 5-10 KOPS（够 SCC 用，SCC 不需要浮点）

### SCC 实时性预算（关键）

64kHz 采样率（PSG 标准）下，每采样 17.3μs = 865 个 50MHz 时钟。
- 单通道 SCC：相位累加（24 位 += step）+ 查表 + 乘音量 ≈ 50-100 拍
- 5 通道轮询：250-500 拍，**远低于 865 拍预算**
- 结论：**50MHz 萤火虫跑 5 通道 SCC 绰绰有余**，还能同时跑 UI/显示

## 五、软件栈全景（来自调用库目录）

萤火虫的"系统"是一套移植的开源 C 库：

| 层 | 内容 | 来源 |
|----|------|------|
| **C 编译器** | GlowCompiler.exe（lcc 移植）| 龙少自研，含 glow.cpp 后端 |
| **数学库** | fdlibm（sin/cos/sqrt/exp/log/pow/atan/...）| Sun 经典库移植 |
| **字符串/mem** | memcpy/memset/memcmp/strlen/strcpy/strncmp | GNU C Library 简化版 |
| **stdlib** | abs/labs/strtod | GNU C Library 简化版 |
| **printf** | 自研（支持 %lld/%f/%llX）| 龙少 |
| **图形库 gl** | DrawRound/DrawLine/DrawFillRound | 龙少 |
| **驱动** | st7789 LCD / ds1302 RTC / ch375 USB / sc16is752 串口 / SD卡 / fatfs | 各类外设 |
| **应用** | 3D渲染 / NES模拟器 / JPEG解码 / 吃豆子 / 科学计算器 / 曼德勃罗分形 | 龙少 |

**这套软件栈证明萤火虫是完整 32 位 C 计算机**，不是 MCU 玩具。SCC/FM 在它上面就是写 C 程序。

## 六、ALU 表的组织（从 glow.cpp glow_cpu_init 反推）

ALU ROM 是 16 位宽（IS61LV12816，128K×16）。地址 = (A, B, XX)：
- A、B 各 8 位 → 16 位地址空间 64K
- XX 是 ALU 模式号，选不同运算（ADD/SUB/AND/OR/XOR/...）
- 输出 16 位：低 8 位是运算结果，高 8 位编码标志位

**关键标志位编码**（从 `17XX` 条件跳转"判 ALU 输出 bit0"推断）：
- bit0：通常是"零标志"或"比较结果"（相等/借位）
- 其他位：进位/符号/溢出（具体编码需看 glow_cpu_init 生成的表）

ALU 表在**编译器初始化阶段生成**（`glow_cpu_init()`，glow.cpp 13182 行起）：
- `ALU_ADD` / `ALU_ADD_C`（带进位）
- `ALU_A_ADD_1`（自增）
- `ALU_EQUAL_C`（相等比较，结果编码到 bit0）
- 其他算术/逻辑运算

**这些表烧进 ROM（下载器灌 SRAM）**，运行时只读。改 ALU = 重新生成 ROM = 重新跑编译器初始化。

## 七、与 PSG 项目的对照（架构延续性）

| 维度 | PSG v0.3 | 萤火虫 1 号 |
|------|---------|------------|
| 数据通路 | 8 位 | 8 位 |
| 主频 | 64kHz | 50MHz（×780）|
| 编程方式 | FT232H 直接写寄存器（C 控制主机）| **C 编译器生成 ROM，CPU 自主执行**|
| 音频生成 | 纯硬件（HC161 计数 + TLC7524）| **软件查表（SRAM 波形 + 算法）**|
| IO | FT232H C口/D口 | CPU 的 IO0/IO1 |
| 灵活性 | 改硬件接线 | 改 C 程序 |
| 复杂度上限 | 组合/时序逻辑到头 | 通用计算机 |

**延续性**：
- 萤火虫的 IO0/IO1 抽象 = PSG 的 FT232H C口/D口抽象（都是"硬件端口当全局变量"）
- 萤火虫的 ALU 查表 = design.md 8.6 节设想的"ALU 用 ROM 查表"（龙少做出来了）
- 萤火虫的下载器（CH340 + 595 灌 SRAM）= PSG 的 FT232H 写寄存器的升级版（灌的是程序不是参数）
- TLC7524 在萤火虫上当 DAC 用 = PSG 已验证的用法

## 八、对 Glowworm-1 子项目的指引（更新）

基于完整软件栈理解，三个方向重新评估：

### 方向 A：完整复刻萤火虫（直插版，~25 片）
- 用 628512（直插版实际用芯片，龙少确认）
- 74HC16374 → 直插版可能用 74HC374 替代
- 优势：可直接跑 GlowCompiler.exe 编译的现有程序（NES/3D/FATFS）
- 适合：把萤火虫当 SCC 平台，最大复用

### 方向 B：最小 SCC 专用机（基于萤火虫 ISA 精简，~15 片）
- 砍 64 位 long long / 浮点（SCC 用不到）
- 砍大地址空间（SCC 波形表几十 KB 够）
- 保留：查表 ALU + IO0/IO1 + 16 位 PC + C 编译器
- 优势：芯片少，面包板可搭
- 代价：失去现有软件栈兼容性

### 方向 C：纯软件路线（先写 ISA 模拟器）
- 用 iverilog/Python 写萤火虫 ISA 行为模型
- 跑 GlowCompiler 编译出的 ROM，验证我们理解
- 在模拟器上开发 SCC 算法，再决定硬件
- 优势：零硬件成本验证理解 + SCC 算法可先行
- 适合：当前阶段最高 ROI

> 我倾向 **C → A**：先用模拟器验证对 ISA 的理解（特别是 ALU 标志位、条件跳转、寻址），同时开发 SCC 算法原型；理解无误后做硬件复刻（A）。但方向需用户拍板。
