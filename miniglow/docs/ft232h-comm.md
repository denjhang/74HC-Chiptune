# MiniGlow FT232H 通信架构（下载/运行复用 FT232H）

> 创建时间：2026-07-05
> 修订时间：2026-07-05（全篇重写，基于萤火虫 C 编译器源码权威证据）
> 权威来源：`E:\...\萤火虫1号\贴片版-萤火虫1号CPU资料\C编译器源码(2023.03.12)\GlowCompiler\`
> - `glow.cpp`（461KB，编译器后端，含 ROM 布局/ALU 自举/指令生成）
> - `GlowCompilerDlg.cpp`（MFC GUI，含**下载协议源码**）
> - `config.h` / `c.h`（ROM/RAM/寄存器堆常量）

---

## 〇、核心方案一句话

**三条独立通路，互不抢占**：

| 通路 | 方向 | 物理接口 | 用途 | miniglow 端口 |
|------|------|---------|------|--------------|
| **FT232H（MODE 切换）** | 双向 | FT_D + FT_A + 控制线 | 下载（MODE=0）+ 上位机通信（MODE=1）| FT_D/FT_A/FT_WE_n/FT_OE_n/FT_CE_n |
| **AUDIO_OUT（音频口）** | 单向输出 | 8 位并口 → TLC7524 D0-D7 | CPU 写采样流，转模拟音频 | AUDIO_OUT[7:0] |
| **协处理器接口** | 双向 | CP_REG_IDX + CP_REG_DATA | CPU 写参数/启动/读结果（SEG=4 段）| CP_REG_IDX/CP_REG_DATA/CP_WE/CP_OE |

**关键**：AUDIO_OUT 是独立单向输出端口，**不走 FT232H**。CPU 执行 `IO0 = sample`（机器码 `0Axx`）直接写到 AUDIO_OUT 引脚，物理接 TLC7524，采样值变化 = 模拟电压变化 = 出声。FT232H 通信走另一条路（SEG=3 段内存映射 IO_OUT/IO_IN）。

**为什么必须独立**：萤火虫原版有 IO0 + IO1 两个独立 IO 口。如果只有一个 IO 口被 FT232H 通信占满，音频就没地方出去——整个项目就没用。AUDIO_OUT 补回了被砍掉的第二个 IO 口，专门做音频输出。

---

## 一、萤火虫原版架构（源码为证的权威事实）

### 1.1 下载器板的硬件组成（来自 Glowworm-1/docs/hardware.md BOM）

萤火虫原版是**两块板**：CPU 板（23 片数字 IC）+ 下载器板（约 10 片数字 IC）。下载口和 IO 口**物理彻底分离**：

| 下载器板 IC | 型号 | 功能 |
|------------|------|------|
| U1 | **CH340N**（SO-8）| USB → 串口（PC 端看到的是 COM 口）|
| U11, U12 | **74HC595 ×2**（串入并出 8 位移位寄存器）| 串口数据串转并，凑出 8 位数据 + 控制位 |
| U4, U5, U10 | **74HC161 ×3**（4 位计数器）| 地址计数器（每收一字节自增，扫 SRAM 地址，3 片 = 12 位地址足够）|
| U2, U3 | **74HC74 ×2**（双 D 触发器）| 控制状态机（协调 595 锁存 / 161 计数 / SRAM WE_n 脉冲）|
| U6 | 74HC14 | 复位整形 |
| U7 | 74HC32 | 控制逻辑 |
| U8 | 74HC08 | 控制逻辑 |
| U9 | 74HC00 | 控制逻辑 |
| U13 | SMD7050-1.8432 | 1.8432MHz（标准串口波特率源）|

**两个连接器**（CPU 板 ↔ 下载器板）：
- **JP1（IDC20, ROM_DATA_LOAD）**：专用下载口，20 针排针。传输 SRAM 地址 + 数据 + WE_n + 时钟
- **JP2（IDC6, CLKMUX）**：时钟切换——下载时用下载器板的 1.8432MHz 时钟，运行时切回 CPU 板的 50MHz

### 1.2 下载协议（来自 `GlowCompilerDlg.cpp`，**最权威**）

**PC 端协议极简——就是 `WriteFile` 把 `rom.bin` 灌进串口**：

```c
// GlowCompilerDlg.cpp L527-543 —— "发送按钮" 消息处理
void CGlowCompilerDlg::OnBnClickedButton3()
{
    CProgressCtrl* myProCtrl2 = (CProgressCtrl*)GetDlgItem(IDC_PROGRESS1);
    DWORD lpNumberOfBytesWritten;
    myProCtrl2->SetRange(0, 1024);
    for (unsigned long i = 0; i < rom_cp; i += 16) {
        if (WriteFile(hCom, &romdata[i], 16, &lpNumberOfBytesWritten, NULL) == false) {
            GetDlgItem(IDC_BUTTON2)->SetWindowTextW(_T("打开串口"));
            CloseComm();
            return;
        }
        myProCtrl2->SetPos(i * 1024 / (rom_cp - 16));
    }
}
```

**协议特征**：
- **数据源**：`romdata[]`（1MB 数组，`ROM_SIZE=1048576`，glow.cpp L27），编译产物 `rom.bin`
- **分块**：每次 16 字节，循环到 `rom_cp`（实际使用的 ROM 字节数）
- **方向**：**纯单向，PC → 硬件**，没有 ACK、没有回读校验、没有握手
- **波特率**：115200 / 230400 / 460800 可选（L112-114）；8 数据位，1 停止位，无校验（L115-117）
- **串口就是 CH340 模拟的 COM 口**（`FindComm()` 从注册表 `HARDWARE\DEVICEMAP\SERIALCOMM` 枚举，L425-448）

### 1.3 ROM 镜像布局（来自 glow.cpp，**颠覆性发现**）

`ROM_SIZE = 1048576`（1MB），`romdata[ROM_SIZE]`（glow.cpp L27, L33）。

`rom.bin` 不只是用户程序，它是**一整块自包含的镜像**：

```
rom.bin (1MB) = [glow_cpu_init() 生成的 ALU 自举指令]   ← 排在最前面
              + [运行时库：memcpy/printf/乘除/浮点等]    ← glow_global_init 入口地址表
              + [用户 main() 及所有调用的函数]
              + [入口跳转指令]    ← romentry (glow.cpp L31, L481)
              + [全局数据/常量]    ← ramallocaddr 分配 (L32, L252)
              + [栈初始化值]       ← sp0/sp1_init_romaddr (L29-30, L474-475, L13667-13669)
```

**CPU 上电流程**：
1. PC 指向 `romentry`（入口跳转指令地址）
2. 跳到 `glow_cpu_init()` 生成的自举代码 → **用 ISA 指令循环填 ALU 表**
3. 跳到运行时库初始化
4. 跳到用户 `main()`

### 1.4 ⚡ 颠覆性发现：ALU 表是运行时自举生成（不是预烧 ROM）

之前 Glowworm-1/docs/hardware.md 推断"ALU ROM 是独立 16 位 SRAM 查表、烧死"。**这是错的**。

来自 `glow.cpp` L13185-13711 的 `glow_cpu_init()` 函数：

```c
// glow.cpp L13185
void glow_cpu_init() {
    ...
    /***** 完整初始化 ALU_ADD 表和 ALU_ADD_C 表 *****/
    _RF_ASGN_IMMNUM(REG_ALU_A, 0);
    _RF_ASGN_IMMNUM(REG_ALU_B, 0);
    label_2 = rom_cp >> 1;
    label_1 = rom_cp >> 1;
    // A 加 B 运算结果写入 ALU
    A_ASGN__RF(REG_ALU_A);
    B_ASGN__RF(REG_ALU_B);
    ALU_ASGN__RF(ALU_ADD, REG_ALU_OUT_0);
    // ... 双重循环遍历 A×B 全组合 256×256，每次写一个 ALU 表项 ...
}
```

**这段是用 ISA 指令写的自举程序**（`A_ASGN__RF` / `B_ASGN_IMMNUM` / `ALU_ASGN__RF` / `IFALU_PC_ASGN_IMMNUM` 都是 ROM 指令生成宏，最终展开成机器码塞进 `romdata[]`）。

CPU 上电**先跑这段自举**，用循环把下列 ALU 模式的所有表项算出来灌进 ALU RAM：
- L13197-13204：`ALU_A_ADD_1`（256 项）
- L13205-13210：`ALU_EQUAL_C`（256 项）
- L13211-13253：`ALU_ADD` / `ALU_ADD_C`（256×256 全组合）
- L13255-13300：`ALU_A_ADD_1_C` / `ALU_A_0_LSH` / `ALU_A_BH_LSH` / `ALU_B_0_LSH` / `ALU_OUTA` / `ALU_OUTB`
- L13302+：`ALU_A_NOT` / `ALU_SUB` / `ALU_AND` / `ALU_OR` / `ALU_XOR` / 移位 / `MUL` / `DIV` / `MOD`

ALU 模式完整清单（来自 `GlowCompilerDlg.cpp` L217-243 的 `alu_str[]`）：
```
ADD SUB ADD_C SUB_C EQUAL_C AND OR A_NOT XOR
A_BH_LSH B_AL_RSH A_AH_RSH A_0_RSH A_0_LSH B_0_LSH
MUL_L MUL_H DIV MOD
A_ADD_1 A_SUB_1 A_ADD_1_C A_SUB_1_C
OUTA OUTB
```

**结论**：ALU RAM（IS61LV12816-51216，128K×16）**不是预先烧死的 ROM**，而是**开机由 CPU 用指令自己初始化**的 SRAM。CR2032 保的是程序+数据 SRAM（U7/U8），ALU RAM 掉电丢失，每次开机自举重建。

### 1.5 ISA 机器码权威定义（来自 `GlowCompilerDlg.cpp` L264-350 反汇编函数）

**16 位定长指令**：高字节 = 操作码（选"源=目的"组合），低字节 = XX（立即数 / ALU 模式号）。

**源选择（高字节高 4 位）**：
| 高 4 位 | 源 | 说明 |
|--------|----|----|
| 0 | 立即数 XX | XX 直接当数据 |
| 1 | ALU[XX] | ALU 查表结果，XX 选模式（见 1.4 模式清单）|
| 2 | RF | 寄存器堆（分页）|
| 3 | RAM | RAM[RA] |
| 4 | IO0 | 独立总线节点，非内存映射 |
| 5 | IO1 | 独立总线节点，非内存映射 |

**目的选择（高字节低 4 位）**：
| 低 4 位 | 目的 |
|--------|------|
| 0 | RF |
| 1 | A（累加器）|
| 2 | A0（地址低字节）|
| 3 | A1（地址中字节）|
| 4 | A2（地址高字节）|
| 5 | RA（RAM 地址指针）|
| 6 | B（ALU 第二输入）|
| 7 | PC（跳转专用）|
| 8 | RAM |
| 9 | ALU[XX]（ALU 输入，XX 选模式）|
| A | IO0 |
| B | IO1 |

**跳转**：
- `07XX` `PC <- A2A1A0`（无条件跳转）
- `17XX` `if(!(ALU[XX] & 0x01)) PC <- A2A1A0`（条件跳转，判 ALU 输出 bit0）
- `27XX` `if(!(RF & 0x01)) PC <- A2A1A0`（判 RF bit0）
- `FFXX` NOP

**寄存器堆分页（来自 glow.cpp L18-24）**：
```c
#define REGISTER_FILE_SP              0    // 堆栈页指针
#define REGISTER_FILE_RET_VALUE       2    // 函数返回值
#define REGISTER_FILE_OP_FUNC_LOP    10    // 运算函数左操作数
#define REGISTER_FILE_OP_FUNC_ROP    18    // 运算函数右操作数
#define REGISTER_FILE_OP_FUNC_DOP    26    // 运算函数目的操作数
#define REGISTER_FILE_OP_FUNC_RET    34    // 运算函数返回地址
#define REGISTER_FILE_OP_FUNC_CACHE  37    // 运算函数缓存区
```

**CPU_O 抽象（glow.cpp L37-45）**：`REG_X = -1`（未知/未跟踪），`REG_F = 256`（寄存器堆页边界）。编译器用这套抽象跟踪地址寄存器（a0/a1/a2/ra）的已知状态，做优化。

### 1.6 IO0/IO1 的硬件语义（来自 `Glowworm-1/docs/architecture.md` 第三节 + ISA 表）

**IO0 / IO1 是两个独立的总线节点**，不是内存映射：
- ISA 高字节 4/5 选 IO0/IO1 当源（CPU 读外设）
- ISA 高字节 A/B 选 IO0/IO1 当目的（CPU 写外设）

**IO0 物理布局（来自 `cpuio.h` 宏定义，architecture.md 第三节引用）**：
```
bit0-2: CS（片选，0-7 选 8 个外设之一）
bit3-7: 数据/控制位（双向，每条线既可输入也可输出）
```
IO0 初始化值 `0xF8`：bit0-2=000（CS0 选中）、bit3-7=11111（数据线默认高）。

**影子寄存器模式**（所有示例程序都用）：
```c
unsigned char IO0_STATE;  // C 层影子，记录上次写出的值
#define IO0_DO_SET_1(data) (IO0_STATE |= (data), IO0 = IO0_STATE)
```
因为读 IO0 拿到的可能是外部输入，不是上次写出的值，所以要维护影子。

---

## 二、miniglow 复用改造方案：FT232H 替代下载器板

### 2.1 改造逻辑（一句话）

**用 FT232H 替换掉下载器板的全部硬件状态机**（CH340 + 595×2 + 161×3 + 74×2 + 逻辑门 ≈ 10 片），下载和运行通信都由 FT232H + 上位机软件完成。

### 2.2 FT232H 的两种模式（MODE 信号线切换）

```
┌─────────────── FT232H（一根 USB 线，复用）───────────────┐
│  C口(ADBUS C0-C7): 8 位数据总线（双用）                 │
│  D口(ACBUS D0-D7): 控制线（双用）                       │
│  D7: MODE 控制线（上位机软件直接拉高/拉低切换模式）      │
└──────────────────────────┬──────────────────────────────┘
                           │
                ┌──────────▼──────────┐
                │  MODE 信号线切换     │
                │                     │
                │  MODE=0（下载）:     │
                │    FT232H C口 → SRAM 数据总线
                │    FT232H 用 GPIO 模拟地址计数（替代 161×3）
                │    FT232H D口 → SRAM WE_n / CE_n / OE_n
                │    CPU 复位态（所有 HC374 OE_n=1，高阻让出）
                │                     │
                │  MODE=1（运行）:     │
                │    FT232H C口 ↔ CPU IO 口（IO0/IO1）
                │    CPU 跑程序，独占 SRAM
                │    FT232H 通过 IO 口和 CPU 交换数据
                └─────────────────────┘
```

### 2.3 MODE=0（下载）—— FT232H 替代 CH340+595+161

**萤火虫原版下载器板做的事**（hardware.md + 1.2 节源码）：
- CH340 收串口字节 → 595×2 串转并凑 8 位数据 → 161×3 地址计数扫 SRAM → 写 WE_n 脉冲

**FT232H 替代后**（参考 PSG2 v0.3 的 `host/psg_adsr_songs_v03.py` 操作风格）：
- **FT232H C口（ADBUS C0-C7）**：直接当 8 位 SRAM 数据总线（替代 595 串转并）
- **FT232H D口（ACBUS D0-D6）**：直接驱动 SRAM 地址 + 控制线（替代 161×3 地址计数 + 74 状态机）
  - D0-D5（6 位）+ C口分时复用凑 19 位地址（miniglow 用 628512 = 512KB = 19 位地址）
  - 或者：地址也走 C口分时（先送地址锁存，再送数据），D口只做控制（LE/WE/OE/CE）
- **FT232H D7**：MODE 信号（上位机软件直接控制）

**上位机协议**（替代原版的串口 WriteFile）：
- 上位机用 ftd2xx 直接驱动 FT232H GPIO（PSG2 v0.3 风格）
- 烧录流程：① D7=0 进 MODE=0 → ② CPU 复位 → ③ 按地址扫描写 rom.bin → ④ D7=1 切 MODE=1 → ⑤ CPU 解除复位跑起来
- **不需要 595 串转并、不需要 161 地址计数**——这些硬件状态机的活全由 FT232H 软件+GPIO 替代

### 2.4 MODE=1（运行通信）—— FT232H 接 CPU IO 口

CPU 跑起来后，FT232H 通过 IO 口和 CPU 交换数据。CPU 视角：
- **写外设**：`IO0 = data`（机器码 `0Axx`）→ FT232H C口读取
- **读外设**：`A = IO0`（机器码 `41xx`，源=IO0）→ FT232H C口驱动

**这是 PSG2 v0.3 FT232H C口/D口操作的同类抽象**（hardware port as global variable），但 miniglow 多了一层 CPU——FT232H 不直接驱动外设芯片，而是通过 CPU 的 IO 口和 CPU 通信。

### 2.5 信号线切换电路（MODE 仲裁）

**关键芯片：HC241（双 4 路三态缓冲，1 片）+ MODE 寄存器（HC74，1 片）**

```
MODE=0（下载）：
  HC241 选通 FT232H → SRAM 通道
  CPU 所有 HC374 OE_n=1（高阻，让出 SRAM 总线）
  FT232H 直接驱动 SRAM 数据/地址/控制

MODE=1（运行）：
  HC241 选通 CPU → SRAM 通道（CPU 独占 SRAM）
  FT232H C口接到 CPU 的 IO0/IO1（通过 HC241 选通）
  CPU 正常跑程序
```

**片数影响**：原 16 片 + HC241×1 + HC74（MODE 寄存器）×1 = 18 片（比萤火虫原版 23 片少 5 片，符合"不严格限制，比原版少即可"）。

---

## 三、miniglow_top.v 的改动点（待实施）

### 3.1 IO 端口拆分（必须改）

**现状（错误）**：`IO0_r` 是单向 output，`CP_D = IO0_r`（L288）——CPU 只能写不能读。

**改为**：
- `IO_OUT` 寄存器：CPU 写，FT232H 读（MODE=1 时 FT232H C口读取 CPU 输出）
- `IO_IN` 寄存器：FT232H 写，CPU 读（MODE=1 时 FT232H C口驱动，CPU 用 `A = IO0` 读）
- **硬件固定方向**（不复用原版 IO0 的 bit0-2=CS 模式，因为 miniglow 用 SEG 段选外设，不用 CS）

### 3.2 协处理器接口换段（必须改）

**现状**：协处理器在 SEG=3 段（L169 `seg3_cp_access`）。

**改为**：SEG=4 段，让出 SEG=3 给 FT232H 通信。
- 机器码层面：测试程序里 `0C03`（`SEG = 3`）改成 `0C04`（`SEG = 4`）
- `tb/miniglow_tb_cp.v` 的测试程序也要跟着改段号

### 3.3 新增 MODE 信号 + 总线仲裁（必须改）

**新增顶层端口**：
```verilog
input wire MODE,        // 0=下载, 1=运行（FT232H D7 控制）
inout wire [7:0] FT_D,  // FT232H C口数据总线（MODE=0 接 SRAM, MODE=1 接 CPU IO）
// FT232H D 口控制线（MODE=0 时驱动 SRAM 地址/控制；MODE=1 时驱动 CPU IO）
```

**新增仲裁逻辑**：
- MODE=0：CPU 所有 HC374 的 OE_n = 1（强制高阻），FT_D 直连 SRAM 数据线
- MODE=1：CPU 正常驱动，FT_D 通过 HC241 接到 CPU 的 IO_OUT/IO_IN

### 3.4 HC241 模型（需新建）

`rtl/hc241.v`——双 4 路三态缓冲器，做总线切换。参考 PSG2 v0.3 已有的 `rtl/hc244.v`（本会话新建）风格。

---

## 四、地址空间分配（修订）

```
SEG=0  程序 ROM（PC 寻址，628512 双字节取指）
SEG=1  RF + 全局变量
SEG=2  通道参数缓冲
SEG=3  ★ FT232H 通信（IO_OUT / IO_IN / 状态标志）—— 本架构新增
SEG=4  ★ 协处理器接口（CP_TYPE/REG_IDX/...）—— 从 SEG=3 改过来
SEG=5+ 预留
```

CPU 程序的通信循环（典型）：
```c
while (1) {
    SEG = 3;  cmd = RAM;          // 读上位机命令
    env_tick();                   // 算 ADSR
    SEG = 4;  CP_START;           // 启动协处理器
    SEG = 4;  sample = CP_OUT;    // 读结果
    SEG = 3;  IO_OUT = sample;    // 输出给上位机
}
```

---

## 五、CPU IO 端口方向控制（决策）

**采用方案 A：硬件固定方向**。
- IO_OUT 只能 CPU 写（FT232H 读）
- IO_IN 只能 CPU 读（FT232H 写）
- 不用原版 IO0 的 bit0-2=CS + bit3-7=双向模式（miniglow 用 SEG 段选，更干净）

**理由**：
1. PSG2 v0.3 也是固定方向（C口数据、D口控制），已验证
2. miniglow 用 SEG 段选外设，不需要 CS 片选
3. 固定方向省掉方向控制寄存器 + 双向逻辑，片数更少

---

## 六、待办（下个窗口执行）

1. **改 miniglow_top.v**：IO 拆 IO_OUT/IO_IN、协处理器 SEG=3→SEG=4、新增 MODE 端口和仲裁
2. **新建 rtl/hc241.v**：双 4 路三态缓冲模型
3. **改 tb/miniglow_tb_cp.v**：测试程序段号 0C03→0C04
4. **写 MODE=0 下载 TB**：验证 FT232H 直驱 SRAM + CPU 高阻
5. **写 MODE=1 通信 TB**：验证 CPU 通过 IO_OUT/IO_IN 和外部交换数据
6. **跑 5 个回归测试**（basic/jmp/jcc/ram/cp）确认无回归

---

## 附录 A：源码证据索引（防遗忘，每条带文件+行号）

### 萤火虫 C 编译器源码位置
`E:\同步文件夹合集\创业 2022.6.17\生产重要资料汇总\生产PCB 工程文件 ROM PLD\产品线-单板机\萤火虫1号\贴片版-萤火虫1号CPU资料\C编译器源码(2023.03.12)\GlowCompiler\`

### 关键证据清单

| 事实 | 出处 |
|------|------|
| ROM 1MB | `glow.cpp` L27 `#define ROM_SIZE 1048576` |
| `romdata[ROM_SIZE]` 定义 | `glow.cpp` L33 |
| 下载 = WriteFile 灌 rom.bin（16 字节/块）| `GlowCompilerDlg.cpp` L527-543 (`OnBnClickedButton3`) |
| 编译产物写 rom.bin | `GlowCompilerDlg.cpp` L409-411 (`OnBnClickedButton1`) |
| 波特率 115200/230400/460800 | `GlowCompilerDlg.cpp` L112-114 |
| 串口配置 8N1 | `GlowCompilerDlg.cpp` L115-117, L508 |
| 串口枚举（CH340 COM 口）| `GlowCompilerDlg.cpp` L425-448 (`FindComm`) |
| `romentry` 入口跳转 | `glow.cpp` L31, L481, L12523 |
| ALU 表自举生成 | `glow.cpp` L13185-13711 (`glow_cpu_init` / `glow_global_init`) |
| ALU 模式清单（25 个）| `GlowCompilerDlg.cpp` L217-243 (`alu_str[]`) |
| ISA 机器码反汇编表 | `GlowCompilerDlg.cpp` L264-350 (`RomData_To_CString`) |
| 寄存器堆分页（SP/RET/LOP/ROP/DOP）| `glow.cpp` L18-24 |
| CPU_O 抽象（REG_X/REG_F）| `glow.cpp` L37-45 |
| 栈初始化（sp0/sp1_init）| `glow.cpp` L29-30, L474-475, L13667-13669 |

### 萤火虫硬件资料（项目内已研究）
- `Glowworm-1/docs/hardware.md` — BOM 反推（CPU 板 23 片 + 下载器板 ~10 片）
- `Glowworm-1/docs/architecture.md` — 软件栈反推（C 数据模型、IO0/IO1 模型、性能预算）
- `Glowworm-1/docs/isa.md` — 官方指令集 xls 整理（与编译器源码一致）

### PSG2 v0.3 FT232H 操作参考
- `psg_voice/PSG2 v0.3/host/psg_adsr_songs_v03.py` — FT232H C口/D口操作协议（`_sd` 设 D 口位、`write_ctrl` 拼数据+锁存）
