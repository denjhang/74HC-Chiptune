// hc138.v — 74HC138 3-to-8 译码器
//
// 74HC138 — 16-pin DIP 封装
// 3 线-8 线译码器/多路分解器
//
// 引脚映射 (DIP-16):
//   Pin  1: A0    Pin 16: VDD
//   Pin  2: A1    Pin 15: Y7
//   Pin  3: A2    Pin 14: Y6
//   Pin  4: EA_n  Pin 13: Y5
//   Pin  5: EB_n  Pin 12: Y4
//   Pin  6: E3    Pin 11: Y3
//   Pin  7: Y0_n  Pin 10: Y2_n
//   Pin  8: GND   Pin  9: Y1_n
//
// 功能:
//   使能: EA_n=0, EB_n=0, E3=1
//   输出 Y_n[7:0] = 仅选中位为 0, 其余为 1

`timescale 1ns/1ps

module hc138 (
    input        A0,    // Pin 1
    input        A1,    // Pin 2
    input        A2,    // Pin 3
    input        EA_n,  // Pin 4: 使能 (低有效)
    input        EB_n,  // Pin 5: 使能 (低有效)
    input        E3,    // Pin 6: 使能 (高有效)
    output       Y0_n,  // Pin 7
    output       Y1_n,  // Pin 9
    output       Y2_n,  // Pin 10
    output       Y3_n,  // Pin 11
    output       Y4_n,  // Pin 12
    output       Y5_n,  // Pin 13
    output       Y6_n,  // Pin 14
    output       Y7_n   // Pin 15
);

    wire [2:0] addr = {A2, A1, A0};
    wire enabled = (~EA_n) & (~EB_n) & E3;

    assign {Y7_n, Y6_n, Y5_n, Y4_n, Y3_n, Y2_n, Y1_n, Y0_n} =
        enabled ? ~(8'b00000001 << addr) : 8'hFF;

endmodule
