// hc373.v — 74HC373 八 D 型透明锁存 (3 态)
//
// 74HC373 — 20-pin DIP 封装
// 8 路透明锁存器, 共享 LE 和 /OE
//
// 引脚映射 (DIP-20) — Nexperia 74HC_HCT373 datasheet:
//   Pin  1: /OE   (输出使能, 低有效)
//   Pin  2: Q0    Pin 12: Q4
//   Pin  3: D0    Pin 13: D4
//   Pin  4: D1    Pin 14: D5
//   Pin  5: Q1    Pin 15: Q5
//   Pin  6: D2    Pin 16: D6
//   Pin  7: Q2    Pin 17: Q6
//   Pin  8: D3    Pin 18: D7
//   Pin  9: Q3    Pin 19: Q7
//   Pin 10: GND   Pin 20: VDD
//   Pin 11: LE    (锁存使能)
//
// 功能:
//   /OE=H: Q = Z (高阻)
//   /OE=L, LE=H: Q = D (透明)
//   /OE=L, LE=L: Q 锁存 (保持)
//
// 本设计 /OE 常接 GND (常输出), 由 LE 控制透明/锁存

`timescale 1ns/1ps

module hc373 (
    input        OE_n,   // Pin 1: 输出使能 (低有效)
    input        LE,     // Pin 11: 锁存使能
    input  [7:0] D,      // Pin 3,4,6,8,13,14,16,18
    output [7:0] Q       // Pin 2,5,7,9,12,15,17,19
);

    reg [7:0] q_reg = 8'h00;

    always @(LE or D) begin
        if (LE)
            q_reg = D;   // 透明: 跟随 D
        // LE=0: 保持 (无操作, q_reg 不变)
    end

    // /OE=0: 输出 q_reg; /OE=1: 高阻
    // 本设计 /OE 常接 GND, 永远输出
    assign Q = OE_n ? 8'hzz : q_reg;

endmodule
