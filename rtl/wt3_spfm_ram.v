// wt3_spfm_ram.v — SPFM 总线 + 62256 参数 RAM
//
// 芯片清单 (4 IC):
//   SPFM 总线 (3): 373 (透明锁存) + 174 (同步器) + 377 (地址寄存器)
//   参数 RAM  (1): 62256 (32K×8)
//
// SPFM 写入流程:
//   1. CPU 写地址 (A0=0) → 377 锁存 reg_addr
//   2. CPU 写数据 (A0=1) → data_wr_pulse 脉冲 → 62256 WE_n=0 写入
//
// 62256 接线:
//   A[7:0]  ← reg_addr (来自 377)
//   DI[7:0] ← reg_data (来自 373)
//   OE_n    ← 1 (写模式下不读, 可通过 RD_n 读取)
//   WE_n    ← ~data_wr_pulse (脉冲低有效)
//   CE_n    ← 0 (始终选中)

`timescale 1ns/1ps

module wt3_spfm_ram (
    input  wire        CLK,
    input  wire        RST_n,
    input  wire [7:0]  D,
    input  wire        A0,
    input  wire        CS_n,
    input  wire        WR_n,
    input  wire        RD_n,

    // RAM 读回 (可选, RD_n=0 时输出)
    output wire [7:0]  ram_do
);

    // ============================================================
    // SPFM 总线 (3 IC: 373, 174, 377)
    // ============================================================
    wire [7:0] reg_addr;
    wire [7:0] reg_data;
    wire       addr_wr_pulse;
    wire       data_wr_pulse;

    wt3_spfm_bus u_spfm (
        .CLK(CLK), .RST_n(RST_n),
        .D(D), .A0(A0),
        .CS_n(CS_n), .WR_n(WR_n), .RD_n(RD_n),
        .reg_addr(reg_addr), .reg_data(reg_data),
        .addr_wr_pulse(addr_wr_pulse),
        .data_wr_pulse(data_wr_pulse)
    );

    // ============================================================
    // U4: 62256 — 参数 RAM
    //   写: SPFM data_wr_pulse → WE_n 低有效
    //   读: RD_n 低有效 → OE_n 低有效
    //   A[14:8] = 0 (只用低 256 字节)
    // ============================================================
    wire ram_we_n = ~data_wr_pulse;
    wire ram_oe_n = RD_n;

    hc62256 u_ram (
        .A0(reg_addr[0]),  .A1(reg_addr[1]),
        .A2(reg_addr[2]),  .A3(reg_addr[3]),
        .A4(reg_addr[4]),  .A5(reg_addr[5]),
        .A6(reg_addr[6]),  .A7(reg_addr[7]),
        .A8(1'b0), .A9(1'b0), .A10(1'b0), .A11(1'b0),
        .A12(1'b0), .A13(1'b0), .A14(1'b0),
        .DI(reg_data),
        .DO(ram_do),
        .CE_n(1'b0),
        .OE_n(ram_oe_n),
        .WE_n(ram_we_n)
    );

endmodule
