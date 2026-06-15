// hc158.v — 74HC158 四路 2 选 1 反相多路选择器
//
// 74HC158 — 16-pin DIP 封装
// 与 157 的区别: 输出反相 (Y = ~selected)
//
// 引脚映射 (DIP-16):
//   Pin  1: Select    (选择输入, 0=A, 1=B)
//   Pin  2: A1   Pin  3: B1   Pin  4: Y1   (反相输出)
//   Pin  5: A2   Pin  6: B2   Pin  7: Y2   (反相输出)
//   Pin 13: A3  Pin 14: B3  Pin 15: Y3  (反相输出)
//   Pin 10: A4  Pin 11: B4  Pin 12: Y4  (反相输出)
//   Pin 16: VDD  Pin  8: GND
//
// 功能:
//   Select=0: Y = ~A (反相 A 输出)
//   Select=1: Y = ~B (反相 B 输出)

`timescale 1ns/1ps

module hc158 (
    input  wire Select,
    input  wire A1, B1,
    input  wire A2, B2,
    input  wire A3, B3,
    input  wire A4, B4,
    output wire Y1,
    output wire Y2,
    output wire Y3,
    output wire Y4
);
    assign Y1 = Select ? ~B1 : ~A1;
    assign Y2 = Select ? ~B2 : ~A2;
    assign Y3 = Select ? ~B3 : ~A3;
    assign Y4 = Select ? ~B4 : ~A4;
endmodule
