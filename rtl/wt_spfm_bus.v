// wt_spfm_bus.v — SPFM 总线接口 (ROM 查表译码, 完全实例化)
//
// 用户自定义 SPFM 协议, 仿 YM2413 两步写时序:
//   写地址: A0=0, CS_n=0, WR_n=0  (RST_n=1)
//   写数据: A0=1, CS_n=0, WR_n=0  (RST_n=1)
//   间隙:   CS_n=1 或 WR_n=1
//
// 时序要求 (主机软件保证):
//   - 写脉冲 (CS_n=0, WR_n=0) 持续 ≥ SPFM_CLK × N
//   - 两次写之间间隔 ≥ SPFM_CLK × M (让 373 锁存稳定)
//
// 架构:
//   U1: 74HC373 — D[7:0] 透明锁存 (le=1 时透明, le=0 时锁存)
//       LE = ROM 输出 DQ2 (写地址/写数据时 le=1)
//   U2: 74HC377 — 地址寄存器 (8-bit)
//       Enable_bar = ROM 输出 DQ0 (addr_wr_n, 写地址时为 0)
//   U3: 39SF040 — 译码 ROM (替代所有组合逻辑门)
//       地址 A3..A0 = {CS_n, WR_n, A0, RST_n}
//       输出 DQ2..DQ0 = {le, data_wr_n, addr_wr_n}
//
// 芯片清单 (3 IC):
//   373 + 377 + 39SF040 (无 174 同步器, 时序由主机保证)

`timescale 1ns/1ps

// ================================================================
// 74HC 芯片定义
// ================================================================

// 74HC373 — 八D透明锁存
// LE=1: Q 跟随 D (透明)
// LE=0: Q 锁存
module spfm_373 (
    input         LE,
    input  [7:0]  D,
    output [7:0]  Q
);
    reg [7:0] latch = 8'h00;
    always @(*) begin
        if (LE) latch = D;
    end
    assign Q = latch;
endmodule

// 74HC377 — 八D触发器 (上升沿, 使能)
module spfm_377 (
    input             Enable_bar,
    input      [7:0]  D,
    input             Clk,
    output reg [7:0]  Q
);
    initial Q = 8'd0;
    always @(posedge Clk) begin
        if (!Enable_bar) Q <= D;
    end
endmodule

// ================================================================
// SPFM 总线接口顶层 (ROM 查表译码)
// ================================================================
module wt_spfm_bus (
    // SPFM 总线 (来自主机) — 只写, RD_n 预留
    input  wire        CLK,
    input  wire        RST_n,
    input  wire [7:0]  D,
    input  wire        A0,
    input  wire        CS_n,
    input  wire        WR_n,
    input  wire        RD_n,    // 预留 (当前未使用)

    // 内部寄存器输出
    //   addr_wr_n / data_wr_n: 直接从 ROM 输出 (active-low), 无隐藏反相
    output wire [7:0]  reg_addr,
    output wire [7:0]  reg_data,
    output wire        addr_wr_n,
    output wire        data_wr_n,
    output wire        le            // 373 透明锁存使能 (诊断用, 一般不接)
);

    // ============================================================
    // U3: 39SF040 — 译码 ROM
    //   地址 A3..A0 = {CS_n, WR_n, A0, RST_n}
    //   A4..A18 = 0
    //   输出:
    //     DQ2 = le        (373 透明锁存使能)
    //     DQ1 = data_wr_n (写数据时为 0)
    //     DQ0 = addr_wr_n (写地址时为 0)
    // ============================================================
    wire [7:0] decode_dq;

    hc39sf040 #(.INIT_FILE("rom/spfm_decode.hex")) u_decode (
        .A0(RST_n),  .A1(A0),     .A2(WR_n),   .A3(CS_n),
        .A4(1'b0),   .A5(1'b0),   .A6(1'b0),   .A7(1'b0),
        .A8(1'b0),   .A9(1'b0),   .A10(1'b0),  .A11(1'b0),
        .A12(1'b0),  .A13(1'b0),  .A14(1'b0),  .A15(1'b0),
        .A16(1'b0),  .A17(1'b0),  .A18(1'b0),
        .DQ(decode_dq),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    wire le_w        = decode_dq[2];
    wire data_wr_n_w = decode_dq[1];
    wire addr_wr_n_w = decode_dq[0];

    // ============================================================
    // U1: 74HC373 — D[7:0] 透明锁存 (写地址或写数据时透明)
    // ============================================================
    wire [7:0] d_latched;

    spfm_373 U1 (
        .LE (le_w),
        .D  (D),
        .Q  (d_latched)
    );

    // ============================================================
    // U2: 74HC377 — 地址寄存器
    //   addr_wr_n=0 时 Enable_bar=0, posedge CLK 锁存 d_latched
    // ============================================================
    wire [7:0] reg_addr_w;

    spfm_377 U2 (
        .Enable_bar (addr_wr_n_w),
        .D          (d_latched),
        .Clk        (CLK),
        .Q          (reg_addr_w)
    );

    // ============================================================
    // 输出
    //   reg_addr:   当前地址 (从 377 读)
    //   reg_data:   当前数据 (从 373 直通, 写数据时锁存的内容)
    //   addr_wr_n:  写地址脉冲 (active-low, 直接来自 ROM DQ0, 无隐藏反相)
    //   data_wr_n:  写数据脉冲 (active-low, 直接来自 ROM DQ1, 无隐藏反相)
    //   le:         373 锁存使能 (诊断用, 一般不接)
    //
    //   全部输出均为 wire 直通 (PCB 导线), 无 ~ 运算符.
    // ============================================================
    assign reg_addr  = reg_addr_w;
    assign reg_data  = d_latched;
    assign addr_wr_n = addr_wr_n_w;
    assign data_wr_n = data_wr_n_w;
    assign le        = le_w;

    // 抑制未使用信号警告
    wire _unused = RD_n;

endmodule
