// cpu39040.v — 39040cpu: 查表机 + 加减法 + SRAM (15 片, 零隐藏门)
//
// 架构: 微指令驱动, PC 直接寻址 ROM, 无锁存, 无04反相
//   3×39SF040: uctl(控制) + udata(立即数) + alu(查表)
//   5× 74HC161 — 20-bit PC
//   2× 74HC377 — AC 累加器, X 地址寄存器
//   4× 74HC157 — bus MUX (udata/ram_do), addr MUX (udata/x_reg)
//   1× HC62256 — SRAM
//
// uctl 格式 (8-bit, 负逻辑编码, 直接连芯片低有效引脚):
//   [0]   ac_dis_n  (1=禁止AC锁存, 直连 377 Enable_bar)
//   [3:1] alu_op    (000=直通, 001=ADD, 010=SUB)
//   [4]   bus_sel   (0=udata, 1=ram_do) → 157 Select
//   [5]   ram_we_n  (0=写SRAM, 直连 62256 WE_n)
//   [6]   mem_sel   (0=udata做地址, 1=x_reg做地址) → 157 Select
//   [7]   to_x_n    (0=锁存x_reg, 直连 377 Enable_bar)

`timescale 1ns/1ps

module cpu39040 (
    input  wire        CLK,
    input  wire        RST_n,
    output wire [7:0]  DATA_OUT
);

    wire clk   = CLK;
    wire rst_n = RST_n;

    // ============================================================
    // 20-bit PC: 5× 74HC161
    // ============================================================
    wire [3:0] pc0_q, pc1_q, pc2_q, pc3_q, pc4_q;
    wire       tc0, tc1, tc2, tc3;

    hc161 u_pc0 (.MR(rst_n), .CP(clk), .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(pc0_q[0]), .Q1(pc0_q[1]), .Q2(pc0_q[2]), .Q3(pc0_q[3]),
        .CEP(1'b1), .CET(1'b1), .PE(1'b1), .TC(tc0));
    hc161 u_pc1 (.MR(rst_n), .CP(clk), .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(pc1_q[0]), .Q1(pc1_q[1]), .Q2(pc1_q[2]), .Q3(pc1_q[3]),
        .CEP(1'b1), .CET(tc0), .PE(1'b1), .TC(tc1));
    hc161 u_pc2 (.MR(rst_n), .CP(clk), .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(pc2_q[0]), .Q1(pc2_q[1]), .Q2(pc2_q[2]), .Q3(pc2_q[3]),
        .CEP(1'b1), .CET(tc1), .PE(1'b1), .TC(tc2));
    hc161 u_pc3 (.MR(rst_n), .CP(clk), .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(pc3_q[0]), .Q1(pc3_q[1]), .Q2(pc3_q[2]), .Q3(pc3_q[3]),
        .CEP(1'b1), .CET(tc2), .PE(1'b1), .TC(tc3));
    hc161 u_pc4 (.MR(rst_n), .CP(clk), .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(pc4_q[0]), .Q1(pc4_q[1]), .Q2(pc4_q[2]), .Q3(pc4_q[3]),
        .CEP(1'b1), .CET(tc3), .PE(1'b1), .TC());

    wire [19:0] pc = {pc4_q, pc3_q, pc2_q, pc1_q, pc0_q};

    // ============================================================
    // ROM: udata — PC 直接寻址
    // ============================================================
    wire [7:0] udata;
    hc39sf040 #(.INIT_FILE("rom/udata.hex")) u_rom_udata (
        .A0(pc[0]), .A1(pc[1]), .A2(pc[2]), .A3(pc[3]),
        .A4(pc[4]), .A5(pc[5]), .A6(pc[6]), .A7(pc[7]),
        .A8(pc[8]), .A9(pc[9]), .A10(pc[10]), .A11(pc[11]),
        .A12(pc[12]), .A13(pc[13]), .A14(pc[14]), .A15(pc[15]),
        .A16(pc[16]), .A17(pc[17]), .A18(pc[18]),
        .DQ(udata), .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // ============================================================
    // ROM: uctl — PC 直接寻址 (负逻辑编码)
    // ============================================================
    wire [7:0] uctl;
    hc39sf040 #(.INIT_FILE("rom/uctl.hex")) u_rom_uctl (
        .A0(pc[0]), .A1(pc[1]), .A2(pc[2]), .A3(pc[3]),
        .A4(pc[4]), .A5(pc[5]), .A6(pc[6]), .A7(pc[7]),
        .A8(pc[8]), .A9(pc[9]), .A10(pc[10]), .A11(pc[11]),
        .A12(pc[12]), .A13(pc[13]), .A14(pc[14]), .A15(pc[15]),
        .A16(pc[16]), .A17(pc[17]), .A18(pc[18]),
        .DQ(uctl), .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // 控制信号: 直连 uctl ROM (零解码门, 低有效信号直接连引脚)
    wire       ac_dis_n = uctl[0];  // 直连 377 Enable_bar
    wire [2:0] alu_op   = uctl[3:1];
    wire       bus_sel  = uctl[4];  // 直连 157 Select
    wire       ram_we_n = uctl[5];  // 直连 62256 WE_n (0=写)
    wire       mem_sel  = uctl[6];  // 直连 157 Select
    wire       to_x_n   = uctl[7];  // 直连 377 Enable_bar (0=锁存)

    // 前向声明
    wire [7:0] ac;

    // ============================================================
    // SRAM 地址 MUX — 2× HC157
    // ============================================================
    wire [7:0] x_reg;
    wire m0, m1, m2, m3, m4, m5, m6, m7;
    hc157 u_mux_mem_lo (
        .Select(mem_sel),
        .A1(udata[0]), .B1(x_reg[0]),
        .A2(udata[1]), .B2(x_reg[1]),
        .A3(udata[2]), .B3(x_reg[2]),
        .A4(udata[3]), .B4(x_reg[3]),
        .Enable_n(1'b0),
        .Y1(m0), .Y2(m1), .Y3(m2), .Y4(m3)
    );
    hc157 u_mux_mem_hi (
        .Select(mem_sel),
        .A1(udata[4]), .B1(x_reg[4]),
        .A2(udata[5]), .B2(x_reg[5]),
        .A3(udata[6]), .B3(x_reg[6]),
        .A4(udata[7]), .B4(x_reg[7]),
        .Enable_n(1'b0),
        .Y1(m4), .Y2(m5), .Y3(m6), .Y4(m7)
    );
    wire [7:0] mem_addr_lo = {m7, m6, m5, m4, m3, m2, m1, m0};

    // ============================================================
    // SRAM — HC62256 (32K×8)
    //   WE_n 直连 uctl[5] (ram_we_n), 0=写
    // ============================================================
    wire [7:0] ram_do;
    hc62256 u_ram (
        .A0(mem_addr_lo[0]),  .A1(mem_addr_lo[1]),  .A2(mem_addr_lo[2]),
        .A3(mem_addr_lo[3]),  .A4(mem_addr_lo[4]),  .A5(mem_addr_lo[5]),
        .A6(mem_addr_lo[6]),  .A7(mem_addr_lo[7]),
        .A8(1'b0), .A9(1'b0), .A10(1'b0), .A11(1'b0),
        .A12(1'b0), .A13(1'b0), .A14(1'b0),
        .DI(ac),
        .DO(ram_do),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(ram_we_n)
    );

    // ============================================================
    // bus MUX — 2× HC157
    // ============================================================
    wire [7:0] alu_d;
    wire b0, b1, b2, b3, b4, b5, b6, b7;
    hc157 u_mux_bus_lo (
        .Select(bus_sel),
        .A1(udata[0]), .B1(ram_do[0]),
        .A2(udata[1]), .B2(ram_do[1]),
        .A3(udata[2]), .B3(ram_do[2]),
        .A4(udata[3]), .B4(ram_do[3]),
        .Enable_n(1'b0),
        .Y1(b0), .Y2(b1), .Y3(b2), .Y4(b3)
    );
    hc157 u_mux_bus_hi (
        .Select(bus_sel),
        .A1(udata[4]), .B1(ram_do[4]),
        .A2(udata[5]), .B2(ram_do[5]),
        .A3(udata[6]), .B3(ram_do[6]),
        .A4(udata[7]), .B4(ram_do[7]),
        .Enable_n(1'b0),
        .Y1(b4), .Y2(b5), .Y3(b6), .Y4(b7)
    );
    assign alu_d = {b7, b6, b5, b4, b3, b2, b1, b0};

    // ============================================================
    // ROM: ALU 查表
    //   地址: alu_d[7:0] | AC[7:0] | alu_op[2:0]
    // ============================================================
    wire [7:0] alu_result;
    hc39sf040 #(.INIT_FILE("rom/alu.hex")) u_rom_alu (
        .A0(alu_d[0]),  .A1(alu_d[1]),  .A2(alu_d[2]),  .A3(alu_d[3]),
        .A4(alu_d[4]),  .A5(alu_d[5]),  .A6(alu_d[6]),  .A7(alu_d[7]),
        .A8(ac[0]),      .A9(ac[1]),      .A10(ac[2]),    .A11(ac[3]),
        .A12(ac[4]),     .A13(ac[5]),    .A14(ac[6]),    .A15(ac[7]),
        .A16(alu_op[0]), .A17(alu_op[1]), .A18(alu_op[2]),
        .DQ(alu_result), .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // ============================================================
    // AC 累加器 — 377
    //   Enable_bar 直连 uctl[0] (ac_dis_n)
    // ============================================================
    hc377 u_ac (
        .Enable_bar(ac_dis_n),
        .D(alu_result),
        .Clk(clk), .Q(ac)
    );

    // ============================================================
    // X 地址寄存器 — 377
    //   Enable_bar 直连 uctl[7] (to_x_n, 0=锁存)
    // ============================================================
    hc377 u_x (
        .Enable_bar(to_x_n),
        .D(alu_result),
        .Clk(clk), .Q(x_reg)
    );

    assign DATA_OUT = ac;

endmodule
