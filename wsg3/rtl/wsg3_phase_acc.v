// wsg3_phase_acc.v — Pac-Man WSG 相位累加器 (按真实网表)
//
// 网表对应:
//   U4: 74HC157 — AB mux
//   U5: 74HC158 — DB 反相 mux
//   U6: 74HC157 — 2L-DQ mux (选寄存器输出)
//   U7: 74HC157 — 2K-DQ mux (选 RAM 输出)
//   U8: 74HC283 — 加法器
//   U9: 74HC174 — 相位锁存

`timescale 1ns/1ps

module wsg3_phase_acc (
    input  wire        CLK,
    input  wire        RST_n,

    // 来自 U11 输出寄存器
    input  wire [7:0]  u11_dq,

    // 来自 U10 RAM
    input  wire [7:0]  u10_dq,

    // 微码控制信号
    input  wire        sel_2l,      // 选 2L 寄存器
    input  wire        sel_2k,      // 选 2K RAM
    input  wire        latch_phase, // 锁存相位

    // 输出
    output wire [7:0]  phase_acc    // 8-bit 相位 (可扩展到 16-bit)
);

    // ============================================================
    // U6: 74HC157 — 2L-DQ mux (选 u11_dq 低 4-bit)
    // ============================================================
    wire [3:0] u6_y;

    hc157 u_u6 (
        .Select(sel_2l),
        .A1(u11_dq[0]), .B1(1'b0), .Y1(u6_y[0]),
        .A2(u11_dq[1]), .B2(1'b0), .Y2(u6_y[1]),
        .A3(u11_dq[2]), .B3(1'b0), .Y3(u6_y[2]),
        .A4(u11_dq[3]), .B4(1'b0), .Y4(u6_y[3]),
        .Enable_n(1'b0)
    );

    // ============================================================
    // U7: 74HC157 — 2K-DQ mux (选 u10_dq 低 4-bit)
    // ============================================================
    wire [3:0] u7_y;

    hc157 u_u7 (
        .Select(sel_2k),
        .A1(u10_dq[0]), .B1(1'b0), .Y1(u7_y[0]),
        .A2(u10_dq[1]), .B2(1'b0), .Y2(u7_y[1]),
        .A3(u10_dq[2]), .B3(1'b0), .Y3(u7_y[2]),
        .A4(u10_dq[3]), .B4(1'b0), .Y4(u7_y[3]),
        .Enable_n(1'b0)
    );

    // ============================================================
    // U8: 74HC283 — 加法器 (u7_y + u6_y)
    // ============================================================
    wire [3:0] adder_s;
    wire       adder_c4;

    hc283 u_u8 (
        .A(u7_y),
        .B(u6_y),
        .C0(1'b0),
        .S(adder_s),
        .C4(adder_c4)
    );

    // ============================================================
    // U9: 74HC174 — 相位锁存
    // ============================================================
    wire [3:0] phase_q;
    reg [7:0] phase_reg;

    hc174 u_u9 (
        .CLR(RST_n),
        .D1(adder_s[0]), .Q1(phase_q[0]),
        .D2(adder_s[1]), .Q2(phase_q[1]),
        .D3(adder_s[2]), .Q3(phase_q[2]),
        .D4(adder_s[3]), .Q4(phase_q[3]),
        .D5(1'b0), .Q5(),
        .D6(1'b0), .Q6(),
        .CLK(CLK)
    );

    always @(posedge CLK or negedge RST_n) begin
        if (!RST_n)
            phase_reg <= 8'h0;
        else if (latch_phase)
            phase_reg <= {phase_reg[7:4], phase_q};
    end

    assign phase_acc = phase_reg;

endmodule
