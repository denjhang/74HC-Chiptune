// hc189.v — 74LS189 16×4-bit 双端口 SRAM 模型
//
// 74LS189 — 16-pin DIP 封装
// 16×4 = 64 bit, 4-bit 地址 (A0-A3)
//
// 引脚映射 (DIP-16):
//   Pin  1: A3'   (读地址 in, 反相输入 — 仿真按 datasheet 逻辑简化)
//   Pin  2: CS_n  (片选, 低有效)
//   Pin  3: WE_n  (写使能, 低有效 — 上升沿锁存写数据)
//   Pin  4: A0'   (读地址)
//   Pin  5: D0    (写数据 in)
//   Pin  6: A1'   (读地址)
//   Pin  7: D1    (写数据 in)
//   Pin  8: GND
//   Pin  9: D2    (写数据 in)
//   Pin 10: A2'   (读地址)
//   Pin 11: D3    (写数据 in)
//   Pin 12: A3    (写地址)
//   Pin 13: A2    (写地址)
//   Pin 14: A1    (写地址)
//   Pin 15: A0    (写地址)
//   Pin 16: VDD
//
// 双端口特性:
//   写端口: A[3:0] + D[3:0], WE_n 上升沿锁存
//   读端口: A'[3:0], 输出反相 (O[3:0] = ~mem[addr']), 仿真中直接给非反相输出
//
// 读操作: CS_n=0, WE_n=1 → O[3:0] = mem[read_addr] (实际硬件反相, 仿真忽略)
// 写操作: CS_n=0, WE_n 上升沿 → mem[write_addr] = D[3:0]

`timescale 1ns/1ps

module hc189 (
    // 写地址 (Pin 15, 14, 13, 12)
    input         A0_w,
    input         A1_w,
    input         A2_w,
    input         A3_w,
    // 读地址 (Pin 4, 6, 10, 1)
    input         A0_r,
    input         A1_r,
    input         A2_r,
    input         A3_r,
    // 写数据 (Pin 5, 7, 9, 11)
    input         D0,
    input         D1,
    input         D2,
    input         D3,
    // 读数据 (实际硬件: Pin 反相输出, 仿真直接给 mem 内容)
    output [3:0]  O,
    // 控制
    input         CS_n,   // Pin 2
    input         WE_n    // Pin 3 (上升沿锁存写)
);

    reg [3:0] mem [0:15];

    integer i;
    initial begin
        for (i = 0; i < 16; i = i + 1)
            mem[i] = 4'b0;
    end

    wire [3:0] w_addr = {A3_w, A2_w, A1_w, A0_w};
    wire [3:0] r_addr = {A3_r, A2_r, A1_r, A0_r};
    wire [3:0] w_data = {D3, D2, D1, D0};

    // 写: WE_n 上升沿且 CS_n=0 时锁存 (双端口: 写端口独立)
    always @(posedge WE_n) begin
        if (!CS_n)
            mem[w_addr] <= w_data;
    end

    // 读: 双端口, 读端口独立于写端口 (CS_n=0 时持续输出)
    // 注: 实际 74LS189 输出反相, 仿真给非反相便于使用
    assign O = (!CS_n) ? mem[r_addr] : 4'bzz;

endmodule
