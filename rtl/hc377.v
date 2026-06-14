// hc377.v — 74HC377 八D触发器 (带使能)
//
// 74HC377 — 20-pin DIP 封装
// 8 路 positive-edge-triggered D 触发器, 共享 CLK 和 Enable
//
// 引脚映射 (DIP-20):
//   Pin  1: Enable_bar (低有效)
//   Pin  2: Q0  Pin 19: D0
//   Pin  3: D1  Pin 18: Q1
//   Pin  4: Q2  Pin 17: D2
//   Pin  5: D3  Pin 16: Q3
//   Pin  6: Q4  Pin 15: D4
//   Pin  7: D5  Pin 14: Q4
//   Pin  8: Q6  Pin 13: D5
//   Pin  9: D7  Pin 12: Q6
//   Pin 10: GND Pin 11: CLK
//   Pin 20: VDD
//
// 功能:
//   Enable_bar=0 且 posedge CLK: Q <= D
//   Enable_bar=1: Q 保持

`timescale 1ns/1ps

module hc377 (
    input        Enable_bar,  // Pin 1
    input  [7:0] D,           // 并行输入
    input        Clk,         // Pin 11
    output [7:0] Q
);

    reg [7:0] q_reg = 8'd0;

    always @(posedge Clk) begin
        if (!Enable_bar)
            q_reg <= D;
    end

    assign Q = q_reg;

endmodule
