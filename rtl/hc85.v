// hc85.v — 74HC85 4 位幅度比较器
//
// 74HC85 — 16-pin DIP 封装
// 4-bit 幅度比较器, 可级联
//
// 引脚映射 (DIP-16, Nexperia 74HC_HCT85):
//   Pin  1: B3    Pin 16: VDD
//   Pin  2: A<B_in Pin 15: A>B_out
//   Pin  3: A=B_in Pin 14: A=B_out
//   Pin  4: A>B_in Pin 13: A<B_out
//   Pin  5: A3    Pin 12: B0
//   Pin  6: B2    Pin 11: A0
//   Pin  7: A2    Pin 10: B1
//   Pin  8: A1    Pin  9: A0... (实际修正)
//
// 实际引脚 (标准 DIP-16):
//   Pin  1: B3    Pin 16: VDD
//   Pin  2: I(A<B) Pin 15: O(A>B)
//   Pin  3: I(A=B) Pin 14: O(A=B)
//   Pin  4: I(A>B) Pin 13: O(A<B)
//   Pin  5: A3    Pin 12: B0
//   Pin  6: B2    Pin 11: A0
//   Pin  7: A2    Pin 10: B1
//   Pin  8: GND   Pin  9: A1
//
// 功能: 比较 A[3:0] 和 B[3:0]
//   O(A>B)=1 当 A > B
//   O(A<B)=1 当 A < B
//   O(A=B)=1 当 A = B
//   级联: 低4位输出 → 高4位输入

`timescale 1ns/1ps

module hc85 (
    input  [3:0] A,       // A3,A2,A1,A0 (Pin 5,7,9,11)
    input  [3:0] B,       // B3,B2,B1,B0 (Pin 1,6,10,12)
    input         A_lt_B_in, // I(A<B) (Pin 2)
    input         A_eq_B_in, // I(A=B) (Pin 3)
    input         A_gt_B_in, // I(A>B) (Pin 4)
    output        A_lt_B_out, // O(A<B) (Pin 13)
    output        A_eq_B_out, // O(A=B) (Pin 14)
    output        A_gt_B_out  // O(A>B) (Pin 15)
);

    // 组合逻辑比较
    wire A_gt_B_comb = (A > B);
    wire A_lt_B_comb = (A < B);
    wire A_eq_B_comb = (A == B);

    // 级联: 当本级相等时, 采用上级(输入)结果
    assign A_gt_B_out = A_gt_B_comb | (A_eq_B_comb & A_gt_B_in);
    assign A_lt_B_out = A_lt_B_comb | (A_eq_B_comb & A_lt_B_in);
    assign A_eq_B_out = A_eq_B_comb & A_eq_B_in;

endmodule
