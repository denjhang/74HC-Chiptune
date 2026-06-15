// hc10.v — 74HC10 三 3 输入与非门
//
// 74HC10 — 14-pin DIP
// 3 个独立 3 输入 NAND
//
// 引脚 (DIP-14):
//   Pin  1: A1   Pin 14: VDD
//   Pin  2: B1   Pin 13: C3
//   Pin  3: B2   Pin 12: B3/A3 (实际 A3)
//   Pin  4: A2/B2 (实际 A2)
//   Pin  5: C2   Pin 11: C3
//   Pin  6: Y2   Pin 10: B3
//   Pin  7: GND  Pin  9: A3
//   Pin  8: Y1   Pin 12: Y3
//
// 简化端口: 直接 3 个 NAND3

`timescale 1ns/1ps

module hc10 (
    input  A1, B1, C1,
    input  A2, B2, C2,
    input  A3, B3, C3,
    output Y1, Y2, Y3
);

    assign Y1 = !(A1 & B1 & C1);
    assign Y2 = !(A2 & B2 & C2);
    assign Y3 = !(A3 & B3 & C3);

endmodule
