// hc02.v — 74HC02 四 2 输入或非门
//
// 74HC02 — 14-pin DIP 封装
// 4 路独立 2 输入 NOR
//
// 引脚映射 (DIP-14):
//   Pin  1: Y1   Pin 14: VDD
//   Pin  2: A1   Pin 13: B4
//   Pin  3: B1   Pin 12: A4
//   Pin  4: Y2   Pin 11: Y4
//   Pin  5: A2   Pin 10: B3
//   Pin  6: B2   Pin  9: A3
//   Pin  7: GND  Pin  8: Y3
//
// 功能: Y = ~(A | B)

`timescale 1ns/1ps

module hc02 (
    input  A1, B1,
    input  A2, B2,
    input  A3, B3,
    input  A4, B4,
    output Y1, Y2, Y3, Y4
);

    assign Y1 = ~(A1 | B1);
    assign Y2 = ~(A2 | B2);
    assign Y3 = ~(A3 | B3);
    assign Y4 = ~(A4 | B4);

endmodule
