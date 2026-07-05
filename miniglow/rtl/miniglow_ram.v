// miniglow_ram.v — miniglow 专用 SRAM 模型（同步写，简化单周期 CPU 时序）
//
// 与 hc628512 引脚基本兼容，增加 CLK 同步写
// 单周期 CPU 里，addr/DI 在 posedge CLK 已稳定，posedge 触发写最干净

`timescale 1ns/1ps

module miniglow_ram (
    input         CLK,        // 新增：同步写时钟
    input         A0, A1, A2, A3, A4, A5, A6, A7,
    input         A8, A9, A10, A11, A12, A13, A14,
    input         A15, A16, A17, A18,

    input  [7:0]  DI,
    output [7:0]  DO,

    input         CE_n,
    input         OE_n,
    input         WE_n
);

    reg [7:0] mem [0:524287];

    integer i;
    initial begin
        for (i = 0; i < 524288; i = i + 1)
            mem[i] = 8'h00;
    end

    wire [18:0] addr = {A18, A17, A16, A15, A14, A13, A12, A11, A10, A9, A8,
                        A7, A6, A5, A4, A3, A2, A1, A0};

    // 同步写：posedge CLK 时，如果 WE_n=0 则写
    // 用 posedge 写避开组合环路（addr/DI 由当前指令组合产生，CLK 边沿锁存）
    always @(posedge CLK) begin
        if (!CE_n && !WE_n)
            mem[addr] <= DI;
    end

    // 读：CE_n=0 且 OE_n=0 且 WE_n=1（组合读，立即响应）
    assign DO = (!CE_n && !OE_n && WE_n) ? mem[addr] : 8'hzz;

endmodule
