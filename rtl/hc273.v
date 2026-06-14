// hc273.v — 74HC273 八 D 触发器 (带异步清零)
//
// 74HC273 — 20-pin DIP 封装
// 8 路 positive-edge-triggered D 触发器, 共享 CP 和 /MR
//
// 引脚映射 (DIP-20) — Nexperia 74HC_HCT273 datasheet:
//   Pin  1: /MR   (异步清零, 低有效)
//   Pin  2: Q0    Pin 12: Q4
//   Pin  3: D0    Pin 13: D4
//   Pin  4: D1    Pin 14: D5
//   Pin  5: Q1    Pin 15: Q5
//   Pin  6: D2    Pin 16: D6
//   Pin  7: Q2    Pin 17: Q6
//   Pin  8: D3    Pin 18: D7
//   Pin  9: Q3    Pin 19: Q7
//   Pin 10: GND   Pin 20: VDD
//   Pin 11: CP    (Clock, 上升沿触发)
//
// 功能:
//   posedge CP: Q <= D
//   /MR=0: Q <= 0 (异步)

`timescale 1ns/1ps

module hc273 #(
    parameter WIDTH = 8,
    parameter DELAY_RISE = 15,
    parameter DELAY_FALL = 15
) (
    input              MR_n,   // Pin 1: 异步清零 (低有效)
    input              CP,     // Pin 11: 时钟 (上升沿触发)
    input  [WIDTH-1:0] D,      // Pin 3,4,6,8,13,14,16,18
    output [WIDTH-1:0] Q       // Pin 2,5,7,9,12,15,17,19
);

    reg [WIDTH-1:0] q_reg = {WIDTH{1'b0}};

    always @(posedge CP or negedge MR_n) begin
        if (!MR_n)
            q_reg <= {WIDTH{1'b0}};
        else
            q_reg <= D;
    end

    assign #(DELAY_RISE, DELAY_FALL) Q = q_reg;

endmodule
