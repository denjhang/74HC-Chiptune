// hc174.v — 74HC174 六D触发器 (带异步清零)
//
// 74HC174 — 16-pin DIP 封装
// 6 路 positive-edge-triggered D 触发器, 共享 CLK 和 CLR
//
// 引脚映射 (DIP-16):
//   Pin  1: CLR   Pin 16: VDD
//   Pin  2: Q1    Pin 15: Q4
//   Pin  3: D1    Pin 14: D4
//   Pin  4: D2    Pin 13: D5
//   Pin  5: Q2    Pin 12: Q5
//   Pin  6: D3    Pin 11: D6
//   Pin  7: Q3    Pin 10: Q6
//   Pin  8: GND   Pin  9: CLK
//
// 功能:
//   posedge CLK: Q <= D
//   CLR=0: Q <= 0 (异步)

`timescale 1ns/1ps

module hc174 (
    input        CLR,   // Pin 1: 异步清零 (低有效)
    input        D1,    // Pin 3
    input        D2,    // Pin 4
    input        D3,    // Pin 6
    input        D4,    // Pin 14
    input        D5,    // Pin 13
    input        D6,    // Pin 11
    input        CLK,   // Pin 9: 时钟 (上升沿触发)
    output       Q1,    // Pin 2
    output       Q2,    // Pin 5
    output       Q3,    // Pin 7
    output       Q4,    // Pin 15
    output       Q5,    // Pin 12
    output       Q6     // Pin 10
);

    reg [5:0] q_reg = 6'd0;

    always @(posedge CLK or negedge CLR) begin
        if (!CLR)
            q_reg <= 6'd0;
        else begin
            // 调试: 检测 X 加载 (仅 hc174 用于 carry chain 时, 即 u9)
            if (^{D6, D5, D4, D3, D2, D1} === 1'bx && $sformatf("%m") == "wsg3_func_tb.u_dut.u_u9")
                $display("    [HC174-X-LOAD @%0t] D=%b%b%b%b%b%b q_old=%b CLK=%b CLR=%b hcnt=%02X",
                    $time, D6, D5, D4, D3, D2, D1, q_reg, CLK, CLR,
                    wsg3_func_tb.u_dut.hcnt_r);
            q_reg <= {D6, D5, D4, D3, D2, D1};
        end
    end

    assign {Q6, Q5, Q4, Q3, Q2, Q1} = q_reg;

endmodule
