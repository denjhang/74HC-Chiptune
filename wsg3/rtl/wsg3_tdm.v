// wsg3_tdm.v — Pac-Man TDM 状态机 + 微码 ROM
//
// 架构:
//   1 片 161: TDM 计数器 (step 0-15)
//   1 片 ROM: 微码 (输出 sel_2l/sel_2k/latch_phase)

`timescale 1ns/1ps

module wsg3_tdm (
    input  wire        CLK,
    input  wire        RST_n,

    // 微码输出
    output wire [3:0]  step,
    output wire        sel_2l,
    output wire        sel_2k,
    output wire        latch_phase
);

    // ============================================================
    // 1 片 161: TDM 计数器
    // ============================================================
    wire tc;

    hc161 u_counter (
        .MR(RST_n),
        .CP(CLK),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .CEP(1'b1),
        .CET(1'b1),
        .PE(1'b1),
        .Q0(step[0]),
        .Q1(step[1]),
        .Q2(step[2]),
        .Q3(step[3]),
        .TC(tc)
    );

    // ============================================================
    // 1 片 ROM: 微码
    // 地址 = step, 输出控制信号
    // ============================================================
    wire [7:0] ucode;

    // 简化版：直接用组合逻辑译码 (不真用 ROM)
    // bit 0: sel_2l
    // bit 1: sel_2k
    // bit 2: latch_phase

    assign sel_2l = (step == 4'b0001);
    assign sel_2k = (step == 4'b0010);
    assign latch_phase = (step == 4'b0011);

endmodule
