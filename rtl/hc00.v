// hc00.v — 74HC00 四 2 输入与非门
//
// 74HC00 — 14-pin DIP 封装
// 4 路独立 2 输入 NAND
//
// 引脚映射 (DIP-14):
//   Pin  1: A1   Pin 14: VDD
//   Pin  2: B1   Pin 13: A4
//   Pin  3: Y1   Pin 12: B4
//   Pin  4: A2   Pin 11: Y4
//   Pin  5: B2   Pin 10: A3
//   Pin  6: Y2   Pin  9: B3
//   Pin  7: GND  Pin  8: Y3
//
// 功能: Y = ~(A & B)

`timescale 1ns/1ps

module hc00 (
    input  A1, B1,
    input  A2, B2,
    input  A3, B3,
    input  A4, B4,
    output Y1, Y2, Y3, Y4
);

    assign Y1 = ~(A1 & B1);
    assign Y2 = ~(A2 & B2);
    assign Y3 = ~(A3 & B3);
    assign Y4 = ~(A4 & B4);

endmodule
