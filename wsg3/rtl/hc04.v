// hc04.v — 74HC04 六反相器
//
// 74HC04 — 14-pin DIP 封装
// 6 路独立反相器
//
// 引脚映射 (DIP-14):
//   Pin  1: A1   Pin 14: VDD
//   Pin  2: Y1   Pin 13: A6
//   Pin  3: A2   Pin 12: Y6
//   Pin  4: Y2   Pin 11: A5
//   Pin  5: A3   Pin 10: Y5
//   Pin  6: Y3   Pin  9: A4
//   Pin  7: GND  Pin  8: Y4
//
// 功能: Y = ~A

`timescale 1ns/1ps

module hc04 (
    input        A1,   // Pin 1
    output       Y1,   // Pin 2
    input        A2,   // Pin 3
    output       Y2,   // Pin 4
    input        A3,   // Pin 5
    output       Y3,   // Pin 6
    input        A4,   // Pin 9
    output       Y4,   // Pin 8
    input        A5,   // Pin 11
    output       Y5,   // Pin 10
    input        A6,   // Pin 13
    output       Y6    // Pin 12
);

    assign Y1 = ~A1;
    assign Y2 = ~A2;
    assign Y3 = ~A3;
    assign Y4 = ~A4;
    assign Y5 = ~A5;
    assign Y6 = ~A6;

endmodule
