// wsg3_channel.v — Pac-Man WSG 单通道 (RAM + 273)
//
// 网表对应:
//   U10: CY62256 RAM (频率/音量存储)
//   U11: 74HC273 (输出寄存器 → 4066)

`timescale 1ns/1ps

module wsg3_channel (
    input  wire        CLK,
    input  wire        RST_n,

    // SPFM 写入
    input  wire [7:0]  reg_addr,
    input  wire [7:0]  reg_data,
    input  wire        ram_we_n,

    // 相位累加器输入
    input  wire [7:0]  phase_acc,

    // 波形 ROM 输入
    input  wire [7:0]  wave_data,

    // 输出
    output wire [7:0]  ram_out,
    output wire [7:0]  dac_out
);

    // ============================================================
    // U10: CY62256 RAM
    // ============================================================
    wire [7:0] ram_do;

    hc62256 u_u10 (
        .A0(reg_addr[0]), .A1(reg_addr[1]), .A2(reg_addr[2]), .A3(reg_addr[3]),
        .A4(reg_addr[4]), .A5(reg_addr[5]), .A6(reg_addr[6]), .A7(reg_addr[7]),
        .A8(1'b0), .A9(1'b0), .A10(1'b0), .A11(1'b0), .A12(1'b0), .A13(1'b0), .A14(1'b0),
        .DI(reg_data),
        .DO(ram_do),
        .CE_n(1'b0),
        .OE_n(1'b0),
        .WE_n(ram_we_n)
    );

    assign ram_out = ram_do;

    // ============================================================
    // U11: 74HC273 — 输出寄存器
    // ============================================================
    wire [7:0] u11_q;

    hc273 #(.WIDTH(8)) u_u11 (
        .MR_n(RST_n),
        .CP(CLK),
        .D(wave_data),
        .Q(u11_q)
    );

    assign dac_out = u11_q;

endmodule
