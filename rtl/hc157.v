// hc157.v — 74HC157 四 2 选 1 数据选择器
//
// 74HC157 — 16-pin DIP 封装
// 4 路 2 选 1 mux, 共享 Select 和 Enable
//
// 引脚映射 (DIP-16):
//   Pin  1: Select (S)
//   Pin  2: A1     Pin  9: Y3
//   Pin  3: B1     Pin 10: A4
//   Pin  4: Y1     Pin 11: B4
//   Pin  5: A2     Pin 12: Y4
//   Pin  6: B2     Pin 13: A3
//   Pin  7: Y2     Pin 14: B3
//   Pin  8: GND    Pin 15: /Enable (低有效)
//   Pin 16: VDD
//
// 功能:
//   Enable_n=1: Y = 0 (所有输出低)
//   Enable_n=0, Select=0: Y = A
//   Enable_n=0, Select=1: Y = B

`timescale 1ns/1ps

module hc157 (
    input         Select,    // Pin 1
    input         A1, B1,    // Pin 2, 3
    input         A2, B2,    // Pin 5, 6
    input         A3, B3,    // Pin 13, 14
    input         A4, B4,    // Pin 10, 11
    input         Enable_n,  // Pin 15
    output        Y1,        // Pin 4
    output        Y2,        // Pin 7
    output        Y3,        // Pin 9
    output        Y4         // Pin 12
);

    assign Y1 = Enable_n ? 1'b0 : (Select ? B1 : A1);
    assign Y2 = Enable_n ? 1'b0 : (Select ? B2 : A2);
    assign Y3 = Enable_n ? 1'b0 : (Select ? B3 : A3);
    assign Y4 = Enable_n ? 1'b0 : (Select ? B4 : A4);

endmodule
