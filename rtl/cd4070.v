// cd4070.v — CD4070B 四 2 输入异或门 (CMOS 4000 系列)
//
// CD4070B — 14-pin DIP 封装 (PDIP-14)
// 4 路独立 2 输入 XOR 门, CMOS 工艺 (VDD = 3-18V)
//
// 引脚映射 (DIP-14, 据 TI CD4070B datasheet Rev.E 核对 2026-07-03):
//   Pin  1: 1A   Pin 14: VDD (+3 ~ +18V)
//   Pin  2: 1B   Pin 13: 4B
//   Pin  3: 1Y   Pin 12: 4A
//   Pin  4: 2Y   Pin 11: 4Y
//   Pin  5: 2A   Pin 10: 3Y   ← ⚠️ 旧版 RTL 把 Pin10 当 3B, 实际是 3Y (输出)
//   Pin  6: 2B   Pin  9: 3B
//   Pin  7: VSS  Pin  8: 3A   ← ⚠️ 旧版 RTL 把 Pin8 当 3Y, 实际是 3A (输入)
//
// 门 1/2/3/4 的输出脚: Pin 3 / Pin 4 / Pin 10 / Pin 11
// 门 2 的 A/B: A=Pin5, B=Pin6 (旧版写反了, XOR 对称不影响功能)
//
// 引脚布局与 74HC86 不同 → 不可复用 hc86 模型, 必须独立建模。
//
// 功能 (每门): Y = A ^ B
//   A B | Y
//   ----+---
//   0 0 | 0
//   0 1 | 1
//   1 0 | 1
//   1 1 | 0
//
// 真值表: 输出 = 输入不相等时为高。
//
// PSG2 v0.3 LFSR 用途:
//   门1: Q7⊕Q5 → 白噪反馈 (Galois LFSR taps)
//   剩余门 2/3/4: 反馈源选通 (白噪/周期噪音 2 选 1)

`timescale 1ns/1ps

module cd4070 (
    input  A1, B1,   // Pin 1, 2
    input  A2, B2,   // Pin 5, 6  (门2: A=Pin5, B=Pin6)
    input  A3, B3,   // Pin 8, 9  (门3: A=Pin8, B=Pin9)
    input  A4, B4,   // Pin 12, 13
    output Y1,       // Pin 3
    output Y2,       // Pin 4
    output Y3,       // Pin 10  ← 门3 输出 (旧版 RTL 错标 Pin 8, 已修正)
    output Y4        // Pin 11
);

    assign Y1 = A1 ^ B1;
    assign Y2 = A2 ^ B2;
    assign Y3 = A3 ^ B3;
    assign Y4 = A4 ^ B4;

endmodule
