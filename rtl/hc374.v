// hc374.v — 74HC374 八 D 触发器 (带 3 态输出)
//
// 74HC374 — 20-pin DIP 封装
// 8 路 positive-edge-triggered D 触发器, 共享 CP 和 /OE
//
// 引脚映射 (DIP-20) — Nexperia 74HC_HCT374 datasheet 5.2 节 (核对 2026-07-07, 读 PDF 原文):
//   Pin  1: /OE  Pin 11: CP (时钟, 上升沿触发)
//   Pin  2: Q0   Pin 12: Q4
//   Pin  3: D0   Pin 13: D4
//   Pin  4: D1   Pin 14: D5
//   Pin  5: Q1   Pin 15: Q5
//   Pin  6: Q2   Pin 16: Q6
//   Pin  7: D2   Pin 17: D6
//   Pin  8: D3   Pin 18: D7
//   Pin  9: Q3   Pin 19: Q7
//   Pin 10: GND  Pin 20: VCC
//
// ⚠️ D 和 Q 交错排列. D 在 Pin 3,4,7,8,13,14,17,18; Q 在 Pin 2,5,6,9,12,15,16,19.
// 注意 74HC574 引脚不同 (D/Q 分边), 别混淆.
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
