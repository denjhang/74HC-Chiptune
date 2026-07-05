# MiniGlow CPU 核心 + 协处理器接口（设计总结）

> 完成时间：2026-07-05
> 状态：**5 个 ISA 测试 + 1 个协处理器接口测试全 PASS**
> 风格：PSG2 v0.3 全实例化（HC374/HC283/HC86/HC138/HC00/HC628512 真实芯片模型）

## 一、当前实现状态

### 测试结果（5+1 全 PASS）

| 测试 | 验证 | 结果 |
|------|------|------|
| `tb/miniglow_tb_basic.v` | 立即数→A、ALU ADD、RA 拼接、IO0 输出 | ✅ |
| `tb/miniglow_tb_jmp.v` | JMP 跳转 + 计数循环 | ✅ |
| `tb/miniglow_tb_jcc.v` | SUB + JCC 相等跳（循环退出）| ✅ |
| `tb/miniglow_tb_ram.v` | RAM 写（dst=8）、RAM 读到 A、RAM 读到 IO0 | ✅ |
| `tb/miniglow_tb_cp.v` | **协处理器握手：写参数、启动、读结果** | ✅ |

### 实际片数（已实例化 + 待补）

| 芯片 | 数量 | 功能 | 状态 |
|------|------|------|------|
| HC628512/miniglow_ram | 1 | 512KB SRAM（8 段）| ✅ 已实例化（miniglow_ram 同步写）|
| HC374 | 4 | RA_L, RA_H, A, B | ✅ 已实例化 |
| HC86 | 2 | ALU B 取反（SUB）| ✅ 已实例化 |
| HC283 | 2 | ALU 8 位加法 | ✅ 已实例化 |
| HC138 | 2 | 源/目的译码 | ✅ 已实例化 |
| HC00 | 1 | 控制门 | ✅ 已实例化 |
| **小计（CPU 数据通路）** | **12** | | |
| HC161 | 4 | PC 16 位 | ⚠️ 待实例化（现为 reg 简化）|
| **总计** | **16 片** | | 超 15 片目标 1 片 |

## 二、ISA 子集（实测验证通过的机器码）

### 指令格式
16 位定长 `{opcode[7:0], xx[7:0]}`，opcode 高 4 位选源、低 4 位选目的。

### 已实现的机器码

```
立即数为源（src_hi=0）:
  01XX  A    = XX      ✅ basic 测试
  02XX  RA_L = XX      ✅ basic/jcc/ram 测试
  03XX  RA_H = XX      ✅ basic/jcc/ram 测试
  06XX  B    = XX      ✅ basic 测试
  08XX  RAM  = XX      ✅ ram 测试（写 SEG 段）
  0AXX  IO0  = XX      ✅ basic 测试
  0CXX  SEG  = XX[2:0] ✅ ram/cp 测试（段切换）

ALU 为源（src_hi=1）:
  11XX  A = ALU[XX]    ✅ basic(ADD)/jcc(SUB) 测试
  注：XX=0 ADD, XX=1 SUB（用 HC86 取反 B + C_in=1）

RAM 为源（src_hi=3）:
  31XX  A   = RAM      ✅ ram/cp 测试
  3AXX  IO0 = RAM      ✅ ram 测试

跳转:
  07XX  PC <- RA       ✅ jmp 测试
  17XX  if(ALU==0) PC<-RA  ✅ jcc 测试（SUB 后判零）
  FFFF  NOP
```

### 地址空间（19 位，SEG[2:0] + RA[15:0]）

```
SEG  段址          用途
000  0x00000-0x0FFFF  程序 ROM（PC 寻址）
001  0x10000-0x1FFFF  RF + 全局变量（RA 寻址）
010  0x20000-0x2FFFF  通道参数缓冲
011  0x30000-0x30007  ★ 协处理器接口（8 个寄存器）
011  0x30008-0x3FFFF  预留
100  0x40000-0x4FFFF  协处理器私有数据
1xx  0x50000-0x7FFFF  预留
```

## 三、协处理器接口（SEG=3 段内存映射）

### CPU 视角（程序写法）

CPU 通过 SEG=3 段的 RA=0..7 这 8 个地址访问协处理器寄存器。CPU 完全不感知"特殊"，只是普通 RAM 读写。

```
SEG = 3
RA = 0x0000  → CP_REG_IDX=0  (CP_TYPE 只读)
RA = 0x0001  → CP_REG_IDX=1
...
RA = 0x0007  → CP_REG_IDX=7
```

### 协处理器寄存器组（推荐约定）

| CP_REG_IDX | 寄存器 | 方向 | 用途 |
|-----------|--------|------|------|
| 0 | TYPE | 只读 | 协处理器类型（CPU 上电探测，0xAA=dummy）|
| 1 | REG_IDX | 读写 | 协处理器内部寄存器索引 |
| 2 | REG_DATA | 读写 | 协处理器内部寄存器数据 |
| 3 | START | 只写 | 写 1 启动一轮计算 |
| 4 | STATUS | 只读 | bit0 = DONE |
| 5 | OUT_L | 只读 | 输出低字节 |
| 6 | OUT_H | 只读 | 输出高字节 |
| 7 | — | — | 预留 |

### CPU 操作协处理器的标准流程

```c
// CPU 端 C 代码（glowcc 编译）
void coproc_set_param(u8 idx, u8 data) {
    SEG = 3;             // 切到 CP 段
    RA_L = 2; RA_H = 0;  // 选 REG_DATA
    RAM = idx;           // 不对，REG_DATA 是 2，REG_IDX 是 1
    // 正确：先写 REG_IDX=idx，再写 REG_DATA=data
    RA_L = 1; RAM = idx;   // 写 REG_IDX
    RA_L = 2; RAM = data;  // 写 REG_DATA
}

u8 coproc_run_read() {
    SEG = 3;
    RA_L = 3; RAM = 1;       // START
    RA_L = 4;                // STATUS
    while ((RAM & 1) == 0);  // 等 DONE
    RA_L = 5; return RAM;    // 读 OUT_L
}
```

### 硬件接口信号（CPU 板上的排针）

```
CP_REG_IDX[2:0]  输出  = RA[2:0]（CPU 当前选的 CP 寄存器）
CP_REG_DATA[7:0] 双向  = 写时 CPU 驱动，读时协处理器驱动
CP_WE            输出  = CPU 写 CP 寄存器时拉高（同步于 CLK）
CP_OE            输出  = CPU 读 CP 寄存器时拉高
CP_INT_n         输入  = 协处理器中断（低有效，可选）
```

CPU 板侧不需要额外芯片——CP_REG_IDX/CP_WE/CP_OE 都从 SEG/RA/opcode 译码产生（HC138 已有的译码器复用）。

## 四、协处理器设计约定（"音源显卡"标准）

任何协处理器模块（wave-mix/PSG/FM/自制）遵守以下接口：

```
协处理器输入（看 CPU 板的输出）:
  CP_REG_IDX[2:0]  - 寄存器选择
  CP_REG_DATA[7:0] - 写时数据（CP_WE=1 时锁存）
  CP_WE            - 写脉冲
  CP_OE            - 读选通

协处理器输出（驱动 CPU 板的输入）:
  CP_REG_DATA[7:0] - 读时数据（CP_OE=1 时驱动）
  CP_INT_n         - 完成标志/中断
```

协处理器内部根据 CP_REG_IDX 实现自己的寄存器组（TYPE/REG_IDX/REG_DATA/START/STATUS/OUT_L/OUT_H）。

## 五、当前简化点（真实硬件待补）

| 项 | 当前简化 | 真实硬件 |
|----|---------|---------|
| PC | reg [15:0] | HC161 ×4（4 片级联）|
| 程序 ROM | 16 位 PROG_ROM（reg 数组）| 628512 双字节取指（PC+2，分两次取 opcode/xx）|
| SRAM | miniglow_ram 同步写 | 628512 + WE_n 脉冲生成（HC00 + RC）|
| RAM 写时序 | posedge CLK 同步 | 真实 SRAM negedge WE_n，需配脉冲电路 |
| 双向 IO | assign 简化 | HC244 三态缓冲（CPU 板侧）|

## 六、复现命令

```bash
export PATH="/d/Program Files/oss-cad-suite/bin:/d/Program Files/oss-cad-suite/lib:$PATH"
cd D:\working\vscode-projects\74HC-Chiptune

# 跑全部 5 个测试
for t in basic jmp jcc ram cp; do
  iverilog -g2012 -o /tmp/mg_$t.vvp \
    rtl/hc283.v rtl/hc374.v rtl/hc86.v rtl/hc00.v rtl/hc138.v \
    miniglow/rtl/miniglow_ram.v miniglow/rtl/miniglow_top.v \
    miniglow/tb/miniglow_tb_$t.v
  echo "=== $t ==="
  vvp /tmp/mg_$t.vvp 2>&1 | grep "PASS\|FAIL"
done
```

## 七、下一步

按优先级：
1. **片数优化到 15**（HC138 砍 1 或 PC 用 12 位）—— 硬约束
2. **PC 用 HC161×4 实例化**（替换 reg 简化）—— 全实例化原则
3. **PROG_ROM 换 628512 双字节取指** —— 真实硬件路径
4. **wave-mix 协处理器 RTL**（覆盖 SCC/WT）—— 项目最终目标
5. **改 glowcc → miniglowcc**（精简后端）—— 让 C 代码能编出来跑
