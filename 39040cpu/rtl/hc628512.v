// hc628512.v — HM628512 512K×8 CMOS Static RAM 模型
//
// HM628512(HL/LP/G/HG-55) — 32-pin DIP / SOP
// 512K×8 = 4,194,304 bits, 19-bit 地址 (A0-A18)
// 55ns access time
//
// 引脚映射 (DIP-32, top view):
//   Pin  1: A18     Pin 32: VDD (5V)
//   Pin  2: A16     Pin 31: A17
//   Pin  3: A14     Pin 30: I/O4
//   Pin  4: A12     Pin 29: A13
//   Pin  5: A7      Pin 28: A8
//   Pin  6: A6      Pin 27: I/O7
//   Pin  7: A5      Pin 26: I/O6
//   Pin  8: A4      Pin 25: I/O5
//   Pin  9: A3      Pin 24: A11
//   Pin 10: A2      Pin 23: I/O2
//   Pin 11: A1      Pin 22: A10
//   Pin 12: A0      Pin 21: CS#
//   Pin 13: I/O0    Pin 20: OE#
//   Pin 14: I/O1    Pin 19: WE#
//   Pin 15: I/O3    Pin 18: A15
//   Pin 16: VSS     Pin 17: A9
//
// 读操作: CS#=0, OE#=0, WE#=1 → tAA=55ns
// 写操作: CS#=0, WE#=0 (OE# 无关) → tWP=40ns
//
// DI/DO 拆分设计: 避免 iverilog inout resolution 问题

`timescale 1ns/1ps

module hc628512 (
    // 地址输入 (19-bit)
    input         A0,  A1,  A2,  A3,  A4,  A5,  A6,  A7,
    input         A8,  A9,  A10, A11, A12, A13, A14, A15,
    input         A16, A17, A18,

    // 数据输入/输出 (8-bit) — 拆分 DI/DO
    input  [7:0]  DI,
    output [7:0]  DO,

    // 控制
    input         CS_n,   // Pin 21: 片选 (低有效)
    input         OE_n,   // Pin 20: 输出使能 (低有效)
    input         WE_n    // Pin 19: 写使能 (低有效)
);

    // 内部存储阵列 — 512K = 524,288 words
    reg [7:0] mem [0:524287];

    integer i;
    initial begin
        for (i = 0; i < 524288; i = i + 1)
            mem[i] = 8'h00;
    end

    // 地址拼接 (19-bit)
    wire [18:0] addr = {A18, A17, A16, A15, A14, A13, A12, A11,
                        A10, A9, A8, A7, A6, A5, A4, A3, A2, A1, A0};

    // 写: WE_n 下降沿锁存, tWP ≥ 40ns
    always @(negedge WE_n) begin
        if (!CS_n)
            #40 mem[addr] <= DI;
    end

    // 读: tAA ≥ 55ns
    assign #55 DO = (!CS_n && !OE_n && WE_n) ? mem[addr] : 8'hzz;

endmodule
