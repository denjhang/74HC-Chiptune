// hc374.v — 74HC374 八 D 触发器 (带 3 态输出)
//
// 74HC374 — 20-pin DIP 封装
// 8 路 positive-edge-triggered D 触发器, 共享 CP 和 /OE
//
// 引脚映射 (DIP-20) — Nexperia 74HC_HCT374 datasheet:
//   Pin  1: /OE  (输出使能, 低有效)
//   Pin  2: Q0   Pin 19: Q7
//   Pin  3: Q1   Pin 18: Q6
//   Pin  4: Q2   Pin 17: Q5
//   Pin  5: Q3   Pin 16: Q4
//   Pin  6: D3   Pin 15: D4
//   Pin  7: D2   Pin 14: D5
//   Pin  8: D1   Pin 13: D6
//   Pin  9: D0   Pin 12: D7
//   Pin 10: GND  Pin 11: CP (时钟, 上升沿触发)
//   Pin 20: VDD
//
// 功能:
//   /OE=0: Q 输出有效, posedge CP → Q <= D
//   /OE=1: Q = Z (高阻), 内部寄存器仍保持

`timescale 1ns/1ps

module hc374 (
    input        OE_n,   // Pin 1: 输出使能 (低有效)
    input        CP,     // Pin 11: 时钟 (上升沿触发)
    input  [7:0] D,      // D0-D7
    output [7:0] Q       // Q0-Q7
);

    reg [7:0] q_reg = 8'd0;

    always @(posedge CP) begin
        q_reg <= D;
    end

    // /OE=0 输出, /OE=1 高阻
    assign Q = OE_n ? 8'hzz : q_reg;

endmodule
