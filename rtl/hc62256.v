// hc62256.v — CY62256N 32K×8 CMOS Static RAM 模型
//
// CY62256N — 28-pin PDIP 封装
// 32K×8 = 262,144 bits, 15-bit 地址 (A0-A14)
//
// 引脚映射 (PDIP-28):
//   Pin  1: A14     Pin 28: VDD (5V)
//   Pin  2: A12     Pin 27: A13
//   Pin  3: A7      Pin 26: A8
//   Pin  4: A6      Pin 25: A9
//   Pin  5: A5      Pin 24: A11
//   Pin  6: A4      Pin 23: OE#
//   Pin  7: A3      Pin 22: A10
//   Pin  8: A2      Pin 21: CE#
//   Pin  9: A1      Pin 20: I/O7
//   Pin 10: A0      Pin 19: I/O6
//   Pin 11: I/O1    Pin 18: I/O5
//   Pin 12: I/O2    Pin 17: I/O4
//   Pin 13: I/O3    Pin 16: I/O0
//   Pin 14: VSS     Pin 15: WE#
//
// 读操作: CE#=0, OE#=0, WE#=1
// 写操作: CE#=0, WE#=0 (OE# 无关)
//
// 本设计用作 4 通道 WT 合成器的通道寄存器存储
// 每通道 16 字节, 4通道 = 64 字节 (62256 有 32KB, 大量空闲)

`timescale 1ns/1ps

module hc62256 (
    // 地址输入 (15-bit, 按 PDIP 引脚命名)
    input         A0, A1, A2, A3, A4, A5, A6, A7,
    input         A8, A9, A10, A11, A12, A13, A14,

    // 数据输入/输出 (8-bit) — 拆分为 DI/DO 避免 inout resolution 问题
    input  [7:0]  DI,
    output [7:0]  DO,

    // 控制
    input         CE_n,   // Pin 21: 片选 (低有效)
    input         OE_n,   // Pin 23: 输出使能 (低有效)
    input         WE_n    // Pin 15: 写使能 (低有效)
);

    // 内部存储阵列
    reg [7:0] mem [0:32767];

    integer i;
    initial begin
        for (i = 0; i < 32768; i = i + 1)
            mem[i] = 8'h00;
    end

    // 地址拼接 (15-bit)
    wire [14:0] addr = {A14, A13, A12, A11, A10, A9, A8,
                        A7, A6, A5, A4, A3, A2, A1, A0};

    // 写: WE_n 下降沿锁存, tWP ≥ 55ns 写脉冲宽度
    reg [7:0] do_r = 8'hzz;

    always @(negedge WE_n) begin
        if (!CE_n)
            #55 mem[addr] = DI;
    end

    // 读: tAA ≥ 55ns 地址访问时间
    // DO 在地址/OE 变化后 55ns 稳定
    reg [7:0] do_read = 8'hzz;
    always @(*) begin
        #55 do_read = (!CE_n && !OE_n) ? mem[addr] : 8'hzz;
    end
    assign #55 DO = do_read;

endmodule
