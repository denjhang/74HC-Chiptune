// hc74.v — 74HC74 双D触发器 (带置位/清零)
//
// 74HC74 — 14-pin DIP 封装
// 2 路独立 positive-edge D 触发器, 各带 PRE (置位) 和 CLR (清零)
//
// 引脚映射 (DIP-14):
//   Pin  1: CLR1  Pin 14: VDD
//   Pin  2: D1    Pin 13: CLR2
//   Pin  3: CLK1  Pin 12: D2
//   Pin  4: PRE1  Pin 11: CLK2
//   Pin  5: Q1    Pin 10: PRE2
//   Pin  6: Q1_n  Pin  9: Q2
//   Pin  7: GND   Pin  8: Q2_n
//
// 功能:
//   PRE=0, CLR=1: Q=1 (异步置位)
//   PRE=1, CLR=0: Q=0 (异步清零)
//   PRE=1, CLR=1, posedge CLK: Q <= D
//   PRE=0, CLR=0: 非法 (Q 与 Q_n 同时为 1)
//
// 作 T 触发器使用: D = Q_n, posedge CLK 时 Q 翻转

`timescale 1ns/1ps

module hc74 (
    input  CLR1, CLK1, D1, PRE1,
    output Q1, Q1_n,
    input  CLR2, CLK2, D2, PRE2,
    output Q2, Q2_n
);

    reg q1 = 1'b0;
    reg q2 = 1'b0;

    always @(posedge CLK1 or negedge PRE1 or negedge CLR1) begin
        if (!PRE1)       q1 <= 1'b1;
        else if (!CLR1)  q1 <= 1'b0;
        else             q1 <= D1;
    end

    always @(posedge CLK2 or negedge PRE2 or negedge CLR2) begin
        if (!PRE2)       q2 <= 1'b1;
        else if (!CLR2)  q2 <= 1'b0;
        else             q2 <= D2;
    end

    assign Q1   = q1;
    assign Q1_n = ~q1;
    assign Q2   = q2;
    assign Q2_n = ~q2;

endmodule
