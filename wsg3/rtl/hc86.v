// hc86.v — 74HC86 四路 2 输入异或门
//
// 74HC86 — 14-pin DIP 封装
// 与 08 的区别: 异或 (Y = A ^ B)
//
// 引脚映射 (DIP-14):
//   Pin  1: A1   Pin  2: B1   Pin  3: Y1
//   Pin  4: A2   Pin  5: B2   Pin  6: Y2
//   Pin  9: Y3   Pin 10: A3   Pin 11: B3
//   Pin 12: Y4   Pin 13: A4   Pin 14: B4
//   Pin  7: GND  Pin 14: VDD
//
// 功能: Y = A ^ B

`timescale 1ns/1ps

module hc86 (
    input  wire A1, B1,
    input  wire A2, B2,
    input  wire A3, B3,
    input  wire A4, B4,
    output wire Y1,
    output wire Y2,
    output wire Y3,
    output wire Y4
);
    assign Y1 = A1 ^ B1;
    assign Y2 = A2 ^ B2;
    assign Y3 = A3 ^ B3;
    assign Y4 = A4 ^ B4;
endmodule
