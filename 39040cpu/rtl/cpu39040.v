// cpu39040.v — 39040cpu: 查表机 + 加减法 (9 片, 零隐藏门)
//
// 架构: 微指令驱动, PC 直接寻址 ROM, 无锁存, 无 MUX
//   3×39SF040: uctl(控制) + udata(立即数) + alu(查表)
//   5× 74HC161 — 20-bit PC
//   1× 74HC377 — AC
//
// 所有操作经过 ALU 查表, 不需要 AC 输入 MUX
//   LD x  = alu_op=000 → ALU 输出 udata (直通)
//   ADD x = alu_op=001 → ALU 输出 AC + udata
//   SUB x = alu_op=010 → ALU 输出 AC - udata
//
// uctl 格式: [0]ac_dis  [3:1]alu_op  [7:4]预留

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
    //   [7:0] 立即数 (全 8 bit 可用)
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
    // ROM: uctl — PC 直接寻址
    //   [0] ac_dis (1=禁止AC锁存, 直连 377 Enable_bar)
    //   [3:1] alu_op[2:0]
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

    // 控制信号: 直连 uctl ROM (组合逻辑, 无锁存)
    wire       ac_dis = uctl[0];
    wire [2:0] alu_op = uctl[3:1];

    // ============================================================
    // ROM: ALU 查表
    //   地址: udata[7:0] | AC[7:0] | alu_op[2:0]
    // ============================================================
    wire [7:0] ac;
    wire [7:0] alu_result;
    hc39sf040 #(.INIT_FILE("rom/alu.hex")) u_rom_alu (
        .A0(udata[0]),  .A1(udata[1]),  .A2(udata[2]),  .A3(udata[3]),
        .A4(udata[4]),  .A5(udata[5]),  .A6(udata[6]),  .A7(udata[7]),
        .A8(ac[0]),      .A9(ac[1]),      .A10(ac[2]),    .A11(ac[3]),
        .A12(ac[4]),     .A13(ac[5]),    .A14(ac[6]),    .A15(ac[7]),
        .A16(alu_op[0]), .A17(alu_op[1]), .A18(alu_op[2]),
        .DQ(alu_result), .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // ============================================================
    // AC 累加器 — 377
    //   输入 = alu_result (所有操作经过 ALU 查表, 无需 MUX)
    //   Enable_bar = ac_dis (直连 uctl[0], 1=禁止)
    // ============================================================
    hc377 u_ac (
        .Enable_bar(ac_dis),
        .D(alu_result),
        .Clk(clk), .Q(ac)
    );

    assign DATA_OUT = ac;

endmodule
