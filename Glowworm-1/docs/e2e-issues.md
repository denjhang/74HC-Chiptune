# 端到端验证发现的问题（verilog 模型 vs 真实编译器输出）

> 2026-07-05
> 用 glowcc 编译 test2/main.c (IO0=0x55) → rom.bin → verilog 模型跑
> 结果：程序卡在 PC≈0x62f 死循环，100000 拍没到 main (PC=0x86B)

## 暴露的 ISA 理解错误

### 错误 1：ALU 模式号 XX 映射

我的 verilog 模型（rtl/glowworm1.v alu_func）：
```
0x00=ADD 0x01=SUB 0x02=AND 0x03=OR 0x04=XOR 0x05=EQUAL 0x06=A_ADD_1
```

实际编译器 alu_str[25]（compiler/GlowCompilerDlg.cpp:230）：
```
0=ADD 1=SUB 2=ADD_C 3=SUB_C 4=EQUAL_C 5=AND 6=OR 7=A_NOT 8=XOR
9=A_BH_LSH 10=B_AL_RSH 11=A_AH_RSH 12=A_0_RSH 13=A_0_LSH 14=B_0_LSH
15=MUL_L 16=MUL_H 17=DIV 18=MOD 19=A_ADD_1 20=A_SUB_1 21=A_ADD_1_C 22=A_SUB_1_C
23=OUTA 24=OUTB
```

差异：EQUAL 我用 0x05，实际 0x04；A_ADD_1 我用 0x06，实际 0x13(=19)；缺 ADD_C/SUB_C 等带进位/借位运算（多字节运算必需）。

### 错误 2：dst=9 (ALU[XX]=源) 的语义

我简化为"A = src_data"，但编译器大量使用：
- `0x2913` RF → ALU：把 RF 喂进 ALU 输入端（xx=A_ADD_1=0x13）
- `0x1913` ALU[XX] → ALU：?

真实语义待查（需对照 glow.cpp 的 ALU_ASGN_RF 函数）。猜测：
- ALU 有两个输入寄存器，dst=9 的 xx 高位决定写哪个输入
- 或 dst=9 是"触发 ALU 计算"，结果在下次 "= ALU[xx]" 时取

### 错误 3：ALU 表是 (A, B, XX) 三元查表

不是简单的 (A, B) 二元。XX 是 ALU ROM 的高位段地址。
ALU 地址 = {XX, A, B}（XX 段选）→ 64K×16 ROM 的某段

我的 verilog 用 case 函数实现，没体现"段"概念。需要按 XX 分段实现所有 25 个函数。

## 结论

verilog 行为模型调试这种语义错误效率太低（每次改要重编 + 跑 100000 拍）。
**转向 C 指令级仿真器**：
- 编译快（秒级）
- 能加详细 trace（每条指令打印状态）
- 能跑真实 ROM 端到端
- 能统计指令/时钟开销（SCC 特化的依据）

verilog 模型保留作"门级实现"参考（后续真实硬件用）。ISA 语义吃透靠 C 仿真器。
