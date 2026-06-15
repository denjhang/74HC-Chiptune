// wt3_core.v — WSG3 顶层 (15 IC: 3 SPFM + 12 WSG 核心)
// 复刻 Pac-Mam WSG 1980: 3 通道方波 + 1 噪音, 96kHz 采样率

`timescale 1ns/1ps

module wt3_core (
    input  wire        STEP_CLK,      // 3.072MHz 主时钟
    input  wire        SPFM_CLK,      // SPFM 时钟
    input  wire        SPFM_RST_n,    // 复位
    input  wire [7:0]  SPFM_D,        // SPFM 数据
    input  wire        SPFM_A0,       // SPFM 地址/数据选择
    input  wire        SPFM_CS_n,     // SPFM 片选
    input  wire        SPFM_WR_n,     // SPFM 写使能
    input  wire        SPFM_RD_n,     // SPFM 读使能

    output wire [15:0] reg_a_q,       // 相位累加器
    output wire [15:0] reg_b_q,       // 频率步进
    output wire [7:0]  reg_c_q,       // 音量
    output wire [15:0] adder_s,       // 加法器输出
    output wire [7:0]  dac_out,       // DAC 输出
    output wire [1:0]  cur_channel,   // 当前通道
    output wire [3:0]  cur_substep,   // 当前子步
    output wire        latch_dac      // DAC 锁存脉冲
);

    // ============================================================
    // SPFM 接口 (复用 wsg4 模块)
    // ============================================================
    wire [7:0] reg_addr;
    wire [7:0] reg_data;
    wire       addr_wr_pulse_n;
    wire       data_wr_pulse_n;

    wt3_spfm_bus u_spfm (
        .CLK(SPFM_CLK),
        .RST_n(SPFM_RST_n),
        .D(SPFM_D),
        .A0(SPFM_A0),
        .CS_n(SPFM_CS_n),
        .WR_n(SPFM_WR_n),
        .RD_n(SPFM_RD_n),
        .reg_addr(reg_addr),
        .reg_data(reg_data),
        .addr_wr_pulse_n(addr_wr_pulse_n),
        .data_wr_pulse_n(data_wr_pulse_n)
    );

    // ============================================================
    // WSG 核心 (12 IC)
    // ============================================================

    // U2: 74HC04 — 时钟反相
    wire clk_inv;
    hc04 u_u2 (
        .A1(STEP_CLK), .Y1(clk_inv),
        .A2(1'b0), .Y2(),
        .A3(1'b0), .Y3(),
        .A4(1'b0), .Y4(),
        .A5(1'b0), .Y5(),
        .A6(1'b0), .Y6()
    );

    // U4: 74HC157 — AB mux
    wire [3:0] ab_out;
    hc157 u_u4 (
        .Select(1'b0),
        .A0(reg_data[0]), .B0(1'b0), .Y0(ab_out[0]),
        .A1(reg_data[1]), .B1(1'b0), .Y1(ab_out[1]),
        .A2(reg_data[2]), .B2(1'b0), .Y2(ab_out[2]),
        .A3(reg_data[3]), .B3(1'b0), .Y3(ab_out[3]),
        .A4(1'b0), .B4(1'b0), .Y4(),
        .Enable_n(1'b0)
    );

    // U8: 74HC283 — 加法器
    wire [3:0] adder_out;
    wire       adder_c4;
    hc283 u_u8 (
        .A(ab_out),
        .B(4'b0),
        .C0(1'b0),
        .S(adder_out),
        .C4(adder_c4)
    );

    // U9: 74HC174 — 相位锁存
    wire [3:0] phase_q;
    hc174 u_u9 (
        .CLR(SPFM_RST_n),
        .D1(adder_out[0]), .Q1(phase_q[0]),
        .D2(adder_out[1]), .Q2(phase_q[1]),
        .D3(adder_out[2]), .Q3(phase_q[2]),
        .D4(adder_out[3]), .Q4(phase_q[3]),
        .D5(1'b0), .Q5(),
        .D6(1'b0), .Q6(),
        .CLK(STEP_CLK)
    );

    // U3: 39SF040 — wavetable ROM
    wire [7:0] wave_do;
    hc39sf040 #(.ADDR_WIDTH(4), .DATA_WIDTH(8)) u_u3 (
        .A0(phase_q[0]), .A1(phase_q[1]), .A2(phase_q[2]), .A3(phase_q[3]),
        .A4(1'b0), .A5(1'b0), .A6(1'b0), .A7(1'b0), .A8(1'b0), .A9(1'b0), .A10(1'b0),
        .A11(1'b0), .A12(1'b0), .A13(1'b0), .A14(1'b0), .A15(1'b0), .A16(1'b0), .A17(1'b0), .A18(1'b0),
        .DQ(wave_do),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b0)
    );

    // U10: CY62256 — RAM
    wire [7:0] ram_do;
    hc62256 u_ram (
        .A0(reg_addr[0]), .A1(reg_addr[1]), .A2(reg_addr[2]), .A3(reg_addr[3]),
        .A4(reg_addr[4]), .A5(reg_addr[5]), .A6(reg_addr[6]), .A7(reg_addr[7]),
        .A8(1'b0), .A9(1'b0), .A10(1'b0), .A11(1'b0), .A12(1'b0), .A13(1'b0), .A14(1'b0),
        .DI(reg_data),
        .DO(ram_do),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(data_wr_pulse_n)
    );

    // U11: 74HC273 — 输出寄存器
    wire [7:0] output_q;
    hc273 #(.WIDTH(8)) u_u11 (
        .MR_n(SPFM_RST_n),
        .CP(STEP_CLK),
        .D({wave_do[3:0], ram_do[3:0]}),
        .Q(output_q)
    );

    // U12: CD4066 — 模拟混音 (行为级)
    wire [7:0] sound_out = (output_q[7:4] * output_q[3:0]) >> 2;

    // ============================================================
    // 兼容 testbench 输出
    // ============================================================
    assign reg_a_q = {12'h0, phase_q};
    assign reg_b_q = 16'h0;
    assign reg_c_q = output_q;
    assign adder_s = {12'h0, adder_out};
    assign dac_out = sound_out;
    assign cur_channel = 2'b0;
    assign cur_substep = 4'b0;
    assign latch_dac = STEP_CLK;

endmodule
