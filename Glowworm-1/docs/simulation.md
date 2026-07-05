# 萤火虫架构仿真验证

> 状态：5 项 ISA 测试 PASS（2026-07-05）
> 模型：`../rtl/glowworm1.v`（行为级抽象，不实例化 74 芯片）
> 目的：在 iverilog 上验证对 ISA 的理解，为后续 SCC 专用架构设计打基础

## 一、模型设计

### 抽象层级

`rtl/glowworm1.v` 是**纯行为级**模型，不模拟真实硬件的芯片级实现，目的是快速验证 ISA 语义。后续做真实硬件时，行为 ALU 换成 SRAM 查表、行为 RF 换成真实 SRAM 即可。

### 存储器模型

| 存储器 | 容量 | 寻址 | 说明 |
|--------|------|------|------|
| `prog_rom` | 64K×16 | PC | 程序，16 位宽（每字一条指令）|
| `rf_ram` | 256×8 | RA | RF 寄存器堆（RA 寻址）|
| `data_ram` | 64K×8 | A2A1A0 | 数据 RAM |
| ALU | 函数查表 | {A,B} | 行为 `case` 实现，可换 SRAM |

### 寄存器

```
A, B    : 8 位 ALU 输入
RA      : 8 位（RF 寻址 + RAM 地址指针）
A0,A1,A2: 各 8 位，拼成 24 位地址 A2A1A0
IO0,IO1 : 8 位双向端口（输出锁存 + 输入采样）
PC      : 24 位（程序计数器，按字 +1）
IR      : 16 位（当前指令 {opcode, xx}）
```

### 关键设计决策（与真实硬件的差异）

| 维度 | 本模型 | 真实硬件 | 影响 |
|------|--------|---------|------|
| ROM 编址 | 16 位宽，PC+1 | 8 位宽，PC+2 | 语义等价（PC 按指令数 vs 字节数）|
| ALU | case 函数 | 64K×16 SRAM 查表 | 后续换 SRAM 即可 |
| 时序 | 单周期/指令 | 多周期（取指+执行）| 仅影响性能，不影响语义 |
| IO 三态 | 简化为输出锁存+输入采样 | 真实三态 | 测试够用 |

## 二、ALU 函数实现

行为 case 实现的 ALU 函数（与 glow.cpp 的 `ALU_ADD`/`ALU_EQUAL_C` 等对应）：

| XX | 函数 | 输出 | bit0 含义 |
|----|------|------|----------|
| 0x00 | ADD | A+B | 进位 |
| 0x01 | SUB | A-B | 无借位（A>=B 时 1）|
| 0x02 | AND | A&B | — |
| 0x03 | OR | A\|B | — |
| 0x04 | XOR | A^B | — |
| 0x05 | EQUAL | bit0=相等标志 | 相等=1，不等=0 |
| 0x06 | A_ADD_1 | A+1 | 溢出（A==FF→1）|

**JCC 判据**：`17XX` 指令判 `alu_rd[0]==0` 跳转。
- 循环条件用 EQUAL：`!=` 时 bit0=0 跳（继续循环），`==` 时 bit0=1 不跳（退出）
- 验证见 JCC 测试

> 待办：对照 glow.cpp `glow_cpu_init()` 校准具体模式号（XX 值）与真实 ALU 表段地址的对应。

## 三、测试结果（全 PASS）

### 测试 1：基础数据通路（`tb/glowworm1_tb_basic.v`）

程序：立即数 0x55 → A → ALU 加 0 → RF[0x10] → IO0
```
A = 0x55       (0x0155)
B = 0x00       (0x0600)
RA = 0x10      (0x0510)
RF = ALU[ADD]  (0x1000)   RF[0x10] = A+B = 0x55
IO0 = RF       (0x2A00)   IO0 = RF[0x10]
```

| 验证项 | 结果 |
|--------|------|
| RF[0x10] = 0x55 | ✅ PASS |
| IO0 = 0x55, oe=1 | ✅ PASS |

**验证的 ISA 概念**：
- RF = RA 寻址的 SRAM（RA=0x10 时访问 RF[0x10]）
- ALU 查 {A,B} 表（A=0x55, B=0x00 → ADD=0x55）
- "目的=源" 统一模型（4 条指令完成数据搬运）

### 测试 2：无条件跳转（`tb/glowworm1_tb_jmp.v`）

程序：循环计数器自增，JMP 回循环开始
```
loop:
  A = RF[0]        (0x2100)
  B = 0x01         (0x0601)
  RA = 0           (0x0500)
  RF[0] = A+B      (0x1000)   counter += 1
  A2A1A0 = loop    (0x0400, 0x0300, 0x0202)
  PC = A2A1A0      (0x07FE)   JMP
```

| 验证项 | 结果 |
|--------|------|
| RF[0] 循环递增到 ≥3 | ✅ PASS |

**验证的 ISA 概念**：
- 无条件跳转 07XX（PC = A2A1A0）
- A2A1A0 24 位地址拼合
- 多周期循环正确

### 测试 3：条件跳转（`tb/glowworm1_tb_jcc.v`）

程序：循环计数到 3 退出（用 EQUAL 比较）
```
init: RF[0] = 0
loop:
  A = RF[0]               取 counter
  B = 0x01
  RF[0] = ALU[ADD]        counter += 1
  A = RF[0]               取新 counter
  B = 0x03                阈值
  A2A1A0 = loop
  if (ALU[EQUAL].bit0==0) PC = A2A1A0   (0x1705)
                            ↑ counter != 3 时跳
exit:
  IO0 = RF[0]             输出最终 counter
```

| 验证项 | 结果 |
|--------|------|
| IO0 = 3（循环到 counter==3 退出）| ✅ PASS |

**验证的 ISA 概念**：
- 条件跳转 17XX（判 ALU.bit0）
- ALU[EQUAL] 标志位编码（bit0 = 相等标志）
- 循环退出语义正确

## 四、编译 + 运行命令

```bash
# 设置 PATH（每次新开终端）
export PATH="/d/Program Files/oss-cad-suite/bin:/d/Program Files/oss-cad-suite/lib:$PATH"

# 跑单个测试
cd D:\working\vscode-projects\74HC-Chiptune
iverilog -g2012 -o /tmp/t.vvp Glowworm-1/rtl/glowworm1.v Glowworm-1/tb/glowworm1_tb_basic.v
vvp /tmp/t.vvp

# 跑全部三个测试
for tb in basic jmp jcc; do
  iverilog -g2012 -o /tmp/$tb.vvp Glowworm-1/rtl/glowworm1.v Glowworm-1/tb/glowworm1_tb_$tb.v
  echo "=== $tb ==="
  vvp /tmp/$tb.vvp 2>&1 | grep -E "PASS|FAIL"
done
```

## 五、C 指令级仿真器（`sim/glowworm_sim.c`）

verilog 行为模型调试 ISA 语义错误效率太低（每次改要重编 + 跑 10 万拍），转用 C 写指令级仿真器。**这是吃透架构的主力工具**——编译秒级、能加详细 trace、能跑真实编译器输出、能统计性能。

### 实现要点

- 严格按 ISA 实现 25 个 ALU 函数（对照编译器 `alu_str[25]`，模式号 0-24）
- 支持 `-mark`（每次 IO0 变化打印 cycle，性能基准用）
- 支持 `-trace start end`（打印指定 cycle 区间指令 trace）
- 支持 `-v`（opcode 直方图）

### 关键 ISA 修正（仿真器调试过程发现）

verilog 模型有两个理解偏差，C 仿真器跑真实 ROM 暴露并修正了：

| 偏差点 | verilog 模型（错）| C 仿真器（对，已验证）|
|--------|-----------------|-------------------|
| 跳转目标 A2A1A0 | 当字节地址直接赋 PC | 是**字地址**，硬件 PC 字节地址 = A2A1A0 × 2 |
| dst=9 (`ALU[XX]=源`) | "A = src_data" | "**触发 ALU 计算 (A,B,xx) + 结果写 RF[RA]**"，src 不参与计算 |

### 端到端验证（C 仿真器跑 glowcc 输出）

`sw/test2/main.c` (`IO0 = 0x55`)：
```
loaded 4370 bytes from rom.bin
[PASS] IO0 = 0x55 at cycle 2130 (pc=0010d8)
insn=2130  cycles=2130
```
2130 拍完成 glow_cpu_init（生成 ALU 表）+ 启动 + main + IO0=0x55。**与编译器 asm.txt 完全一致**。

### SCC 性能基准（核心成果）

移植 STC_Chiptune/scc.c 到萤火虫，单通道混音手动展开防 lcc 死代码消除：

```
单通道 SCC 混音 = 580 拍/采样
```

| 主频 | 单通道采样率 | 5 通道采样率 | vs SCC 标准 (17640 Hz) |
|------|------------|------------|----------------------|
| 8 MHz | 13793 Hz | **2758 Hz** | ❌ 差 6.4 倍 |
| 50 MHz | 86206 Hz | **17241 Hz** | ⚠️ 刚好够（无余量）|

详见 `scc-benchmark.md`。

## 六、待办

### 已完成
- [x] ALU 模式号 XX 校准（对照编译器 alu_str[25]）
- [x] dst=9 (`ALU[XX]=源`) 真实语义（触发计算 + 写 RF[RA]）
- [x] 跑真实 glowcc 输出的 ROM（端到端 2130 拍 PASS）
- [x] 验证 32 位运算（C int = 4 字节，多字节 ALU 进位链）
- [x] SCC 单通道实测（580 拍/采样）
- [x] 8 MHz vs 50 MHz 主频适配性结论（5 通道 8MHz 不够，必须特化）

### 进行中
- [ ] 确认 lcc 对 `u8 * u8` 是否用 MUL_L 单指令（asm.txt 调查）

### 待办
- [ ] 修复函数调用约定（OUTA/OUTB ALU 模式语义）让 scc_render 可调用
- [ ] 测 5 通道 scc_render 全变量（当前只有单通道手动展开数据）
- [ ] 设计 SCC 专用指令集的 ISA 编码
- [ ] 在仿真器加 SCC 专用指令，测性能提升

### verilog 模型 vs C 仿真器
verilog 模型（`rtl/glowworm1.v`）保留作"门级实现"参考（后续真实硬件用），但它有两个未修正的偏差（见上表），不再用于 ISA 验证。ISA 语义吃透靠 C 仿真器。后续若要用 verilog，需要把这两个修正回填。
