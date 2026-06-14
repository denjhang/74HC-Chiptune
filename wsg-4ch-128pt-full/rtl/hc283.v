// hc283.v — 74HC283 4-bit 全加器
//
// 74HC283 — 16-pin DIP 封装
// 4-bit 二进制全加器, 带进位输入/输出
//
// 引脚映射 (DIP-16):
//   Pin  1: A3    Pin 16: VDD
//   Pin  2: B3    Pin 15: Σ3
//   Pin  3: A2    Pin 14: Σ2
//   Pin  4: B2    Pin 13: Σ1
//   Pin  5: A1    Pin 12: Σ0
//   Pin  6: B1    Pin 11: C0 (进位输入)
//   Pin  7: GND   Pin 10: C4 (进位输出)
//   Pin  8: NC    Pin  9: NC
//   (16-pin DIP, Pin 7=GND, Pin 16=VDD, 无额外 NC 脚)
//
// 功能: Σ[3:0] = A[3:0] + B[3:0] + C0
//        C4 = 进位输出

`timescale 1ns/1ps

module hc283 (
    input  [3:0] A,     // 加数 A (Pin 1,3,5,6 → A3,A2,A1,A0)
    input  [3:0] B,     // 加数 B (Pin 2,4,13,12 → B3,B2,B1,B0)
    input         C0,   // 进位输入 (Pin 11)
    output [3:0] S,     // 和 (Pin 15,14,12→Σ1... 修正: Σ3,Σ2,Σ1,Σ0)
    output        C4    // 进位输出 (Pin 10)
);

    wire [4:0] sum = {1'b0, A} + {1'b0, B} + {4'b0, C0};

    assign S  = sum[3:0];
    assign C4 = sum[4];

endmodule
