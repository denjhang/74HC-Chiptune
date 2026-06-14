// hc161.v — 74HC161 同步 4-bit 二进制计数器
//
// 74HC161 — 16-pin DIP 封装
// 同步可预置二进制计数器, 带进位前瞻
//
// 引脚映射 (DIP-16):
//   Pin  1: MR   (异步清零, 低有效)
//   Pin  2: CP   (时钟, 上升沿触发)
//   Pin  3: D0   Pin 14: D3
//   Pin  4: D1   Pin 13: Q3
//   Pin  5: D2   Pin 12: Q2
//   Pin  6: Q0   Pin 11: Q1
//   Pin  7: CEP  (计数使能, 高有效)
//   Pin  8: GND  Pin  9: PE (并行使能, 低有效)
//   Pin 10: CET  (计数使能串级)
//   Pin 15: TC   (终端计数输出)
//   Pin 16: VDD
//
// 功能:
//   MR=0:     Q = 0000 (异步清零)
//   PE=0:     posedge CP → Q = D[3:0] (同步预置)
//   CEP=1,CET=1,PE=1: posedge CP → Q = Q + 1
//   TC = CET & (Q == 4'b1111)

`timescale 1ns/1ps

module hc161 (
    input        MR,    // Pin 1: 异步清零 (低有效)
    input        CP,    // Pin 2: 时钟
    input        D0,    // Pin 3
    input        D1,    // Pin 4
    input        D2,    // Pin 5
    input        D3,    // Pin 14
    output       Q0,    // Pin 6
    output       Q1,    // Pin 11
    output       Q2,    // Pin 12
    output       Q3,    // Pin 13
    input        CEP,   // Pin 7: 计数使能
    input        CET,   // Pin 10: 计数使能串级
    input        PE,    // Pin 9: 并行使能 (低有效)
    output       TC     // Pin 15: 终端计数
);

    reg [3:0] q_reg = 4'd0;

    wire [3:0] d_in = {D3, D2, D1, D0};

    always @(posedge CP or negedge MR) begin
        if (!MR)
            q_reg <= 4'd0;
        else if (!PE)
            q_reg <= d_in;
        else if (CEP && CET)
            q_reg <= q_reg + 4'd1;
    end

    assign {Q3, Q2, Q1, Q0} = q_reg;
    assign TC = CET & (q_reg == 4'b1111);

endmodule
