// wt3_spfm_bus.v — SPFM 总线接口 (3 IC: 373, 174, 377)
//
// YM2413 风格双步写协议:
//   写地址: A0=0, CS_n=0, WR_n=0 → addr_wr 脉冲
//   写数据: A0=1, CS_n=0, WR_n=0 → data_wr 脉冲
//   间隙:   CS_n=1 或 WR_n=1
//
// 架构 (3 显式芯片实例):
//   U1: 74HC373 — D[7:0] 透明锁存
//       LE = ~(CS_n | WR_n)  (CS=0 & WR=0 时透明) — 外部协议译码
//       /OE = GND (常输出)
//   U2: 74HC174 — 同步器 (5 级 D-FF: 3 级 addr_wr + 2 级 data_wr)
//       输入: addr_wr_comb / data_wr_comb (外部协议译码)
//       输出: 延迟后的同步电平
//   U3: 74HC377 — 地址寄存器
//       Enable_bar = ~addr_sync_r3 (取反, 外部协议译码)
//
// 同步链:
//   主机信号 → 异步锁存(373) → 外部协议译码 → 3级同步(174) → 延迟输出
//
// 输出极性: 全部低有效 (与 CS_n/WR_n/RD_n/RST_n 一致)
//   addr_wr_pulse_n: 写地址脉冲 (低有效, 直连 377 Enable_bar)
//   data_wr_pulse_n: 写数据脉冲 (低有效, 直连 62256 WE_n)
//
// 外部协议译码 (PCB 飞线, 不归声卡):
//   write_active = ~CS_n & ~WR_n & RST_n
//   addr_wr_comb = write_active & ~A0
//   data_wr_comb = write_active & A0

`timescale 1ns/1ps

module wt3_spfm_bus (
    input  wire        CLK,
    input  wire        RST_n,
    input  wire [7:0]  D,
    input  wire        A0,
    input  wire        CS_n,
    input  wire        WR_n,
    input  wire        RD_n,

    // 内部寄存器输出
    output wire [7:0]  reg_addr,
    output wire [7:0]  reg_data,

    // 写脉冲 (低有效, 由 74HC04 反相 174 同步链输出得到)
    output wire        addr_wr_pulse_n,
    output wire        data_wr_pulse_n
);

    // ============================================================
    // 外部协议译码 (PCB 飞线, 不算声卡内部门)
    // ============================================================
    wire le          = ~(CS_n | WR_n);
    wire write_active = ~CS_n & ~WR_n & RST_n;
    wire addr_wr_comb = write_active & ~A0;
    wire data_wr_comb = write_active & A0;

    // ============================================================
    // U1: 74HC373 — D[7:0] 透明锁存 (真实芯片实例)
    //   LE=1: Q = D (透明)
    //   LE=0: Q 锁存
    //   /OE 常接 GND
    // ============================================================
    wire [7:0] d_latch;

    hc373 u_d_latch (
        .OE_n(1'b0),    // Pin 1: 常输出
        .LE(le),        // Pin 11: CS_n=0 & WR_n=0 时透明
        .D(D),          // Pin 3,4,6,8,13,14,16,18: SPFM_D[7:0]
        .Q(d_latch)     // Pin 2,5,7,9,12,15,17,19
    );

    assign reg_data = d_latch;

    // ============================================================
    // U2: 74HC174 — 同步器 (5 个 D-FF 用, 1 路未用)
    //
    // 同步链 (3 级 addr_wr + 2 级 data_wr):
    //   addr: addr_wr_comb → Q1 → Q2 → Q3
    //   data: data_wr_comb → Q4 → Q5
    //
    //   addr_wr_pulse_n = ~Q3: write_active 变高后第 3 个 clk 变低
    //     377 在该 posedge 看到 Enable_bar=0, 锁存 d_latch
    //   data_wr_pulse_n = ~Q5: write_active 变高后第 2 个 clk 变低
    //     62256 WE_n 变低, 在下一个 posedge 前写入完成
    // ============================================================

    wire addr_q1, addr_q2, addr_q3;
    wire data_q1, data_q2;

    hc174 u_sync (
        .CLR(RST_n),
        .D1(addr_wr_comb),   // Pin 3 → Q1
        .D2(addr_q1),        // Pin 4 → Q2
        .D3(addr_q2),        // Pin 6 → Q3
        .D4(data_wr_comb),   // Pin 14 → Q4
        .D5(data_q1),        // Pin 13 → Q5
        .D6(1'b0),           // Pin 11 未用 (D6 接 GND)
        .CLK(CLK),           // Pin 9
        .Q1(addr_q1),        // Pin 2
        .Q2(addr_q2),        // Pin 5
        .Q3(addr_q3),        // Pin 7
        .Q4(data_q1),        // Pin 15
        .Q5(data_q2),        // Pin 12
        .Q6()                // Pin 10 未用
    );

    // ============================================================
    // 74HC04 — 六反相器 (声卡内部: 174 同步链 Q 反相 → 低有效脉冲)
    //   Y1 = ~addr_q3 → addr_wr_pulse_n (送 u_addr_reg/377 /Enable)
    //   Y2 = ~data_q2 → data_wr_pulse_n (送外部 u_we_oe_mux/157 A1)
    // 其余 4 路未用, 接 GND
    // ============================================================
    hc04 u_inv_spfm (
        .A1(addr_q3), .Y1(addr_wr_pulse_n),
        .A2(data_q2), .Y2(data_wr_pulse_n),
        .A3(1'b0),    .Y3(),
        .A4(1'b0),    .Y4(),
        .A5(1'b0),    .Y5(),
        .A6(1'b0),    .Y6()
    );

    // ============================================================
    // U3: 74HC377 — 地址寄存器
    //   posedge CLK, Enable_bar=0 时锁存
    //   addr_wr_pulse_n=0 时 Enable_bar=0 (直连, 无隐藏反相)
    //   d_latch 在此之前已由 373 锁存 (CS/WR 恢复后 LE=0)
    // ============================================================
    hc377 u_addr_reg (
        .Enable_bar(addr_wr_pulse_n),
        .D(d_latch),
        .Clk(CLK),
        .Q(reg_addr)
    );

endmodule
