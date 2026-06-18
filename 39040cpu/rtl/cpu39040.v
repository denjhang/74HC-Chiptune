// cpu39040.v — 39040cpu: 图灵完备 CPU (22 片, 零隐藏门)
//
//   4×39SF040: uctl_lo + uctl_hi + udata + alu
//   5× 74HC161 — 20-bit PC
//   4× 74HC377 — AC, X, Y, OUT
//   4× 74HC157 — bus MUX, addr MUX
//   1× HC62256 — SRAM
//   2× HC32    — zero_flag OR tree (7g) + cond OR (1g)
//   1× HC08    — cond AND (3g)
//   1× HC04    — cond NOT (4g) + zero_flag NOT (1g)
//
// uctl_lo: [0]ac_dis_n [3:1]alu_op [4]bus_sel [5]ram_we_n [6]mem_sel [7]to_x_n
// uctl_hi: [0]jmp_dis_n (0=JMP使能) [1]to_y_n [2]to_out_n [3]cond_en
//          [4]cond_sel (0=always, 1=zero) [7:5]预留
//
// 条件逻辑:
//   any_bit_set = OR(ac[7], ac[6], ..., ac[0])         — hc32 OR tree (7 gates)
//   zero_flag   = NOT(any_bit_set)                       — hc04 Y3
//   cond_sel_n  = NOT(cond_sel)                         — hc04 Y1
//   jmp_en      = NOT(jmp_dis_n)                        — hc04 Y2
//   t_uncond    = cond_en AND cond_sel_n                — hc08 Y1
//   t_zero      = cond_en AND zero_flag                 — hc08 Y2
//   cond_result = t_uncond OR t_zero                    — hc32 Y4 spare
//   cond_taken  = jmp_en AND cond_result                — hc08 Y3
//   pc_pe_n     = NOT(cond_taken)                       — hc04 Y4

`timescale 1ns/1ps

module cpu39040 (
    input  wire        CLK,
    input  wire        RST_n,
    output wire [7:0]  DATA_OUT
);

    wire clk   = CLK;
    wire rst_n = RST_n;

    wire [19:0] pc;
    wire [3:0] pc0_q, pc1_q, pc2_q, pc3_q, pc4_q;
    wire       tc0, tc1, tc2, tc3;

    wire [7:0] uctl_lo, uctl_hi, udata;
    wire [7:0] ac, x_reg, y_reg;
    wire [7:0] alu_d, alu_result, ram_do, out_reg;

    // ---- ROM (uctl_lo + uctl_hi + udata) ----
    hc39sf040 #(.INIT_FILE("rom/uctl_lo.hex")) u_rom_uctl_lo (
        .A0(pc[0]), .A1(pc[1]), .A2(pc[2]), .A3(pc[3]),
        .A4(pc[4]), .A5(pc[5]), .A6(pc[6]), .A7(pc[7]),
        .A8(pc[8]), .A9(pc[9]), .A10(pc[10]), .A11(pc[11]),
        .A12(pc[12]), .A13(pc[13]), .A14(pc[14]), .A15(pc[15]),
        .A16(pc[16]), .A17(pc[17]), .A18(pc[18]),
        .DQ(uctl_lo), .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );
    hc39sf040 #(.INIT_FILE("rom/uctl_hi.hex")) u_rom_uctl_hi (
        .A0(pc[0]), .A1(pc[1]), .A2(pc[2]), .A3(pc[3]),
        .A4(pc[4]), .A5(pc[5]), .A6(pc[6]), .A7(pc[7]),
        .A8(pc[8]), .A9(pc[9]), .A10(pc[10]), .A11(pc[11]),
        .A12(pc[12]), .A13(pc[13]), .A14(pc[14]), .A15(pc[15]),
        .A16(pc[16]), .A17(pc[17]), .A18(pc[18]),
        .DQ(uctl_hi), .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );
    hc39sf040 #(.INIT_FILE("rom/udata.hex")) u_rom_udata (
        .A0(pc[0]), .A1(pc[1]), .A2(pc[2]), .A3(pc[3]),
        .A4(pc[4]), .A5(pc[5]), .A6(pc[6]), .A7(pc[7]),
        .A8(pc[8]), .A9(pc[9]), .A10(pc[10]), .A11(pc[11]),
        .A12(pc[12]), .A13(pc[13]), .A14(pc[14]), .A15(pc[15]),
        .A16(pc[16]), .A17(pc[17]), .A18(pc[18]),
        .DQ(udata), .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // ---- uctl 信号 ----
    wire       ac_dis_n  = uctl_lo[0];
    wire [2:0] alu_op    = uctl_lo[3:1];
    wire       bus_sel   = uctl_lo[4];
    wire       ram_we_n  = uctl_lo[5];
    wire       mem_sel   = uctl_lo[6];
    wire       to_x_n    = uctl_lo[7];

    wire       jmp_dis_n = uctl_hi[0]; // 0=JMP使能 (负逻辑)
    wire       to_y_n    = uctl_hi[1];
    wire       to_out_n  = uctl_hi[2];
    wire       cond_en   = uctl_hi[3];
    wire       cond_sel  = uctl_hi[4]; // 0=always, 1=zero

    // ---- zero_flag = NOT(OR(ac[7:0])) ----
    // 2× hc32 = 8 OR gates: 7 for 8-input OR tree, 1 spare for cond OR
    wire or_n0, or_n1, or_n2, or_n3, or_n4, or_n5;
    wire any_bit_set, zero_flag;
    hc32 u_or_a (
        .A1(ac[0]), .B1(ac[1]), .Y1(or_n0),
        .A2(ac[2]), .B2(ac[3]), .Y2(or_n1),
        .A3(ac[4]), .B3(ac[5]), .Y3(or_n2),
        .A4(ac[6]), .B4(ac[7]), .Y4(or_n3)
    );

    // ---- 条件分支 (全实例化, 零隐藏门) ----
    wire cond_sel_n, jmp_en, t_uncond, t_zero, cond_result, cond_taken;
    wire pc_pe_n;

    hc32 u_or_b (
        .A1(or_n0),    .B1(or_n1),    .Y1(or_n4),
        .A2(or_n2),    .B2(or_n3),    .Y2(or_n5),
        .A3(or_n4),    .B3(or_n5),    .Y3(any_bit_set),
        .A4(t_uncond), .B4(t_zero),   .Y4(cond_result)
    );

    hc04 u_inv (
        .A1(cond_sel),    .Y1(cond_sel_n),
        .A2(jmp_dis_n),   .Y2(jmp_en),
        .A3(any_bit_set), .Y3(zero_flag),
        .A4(cond_taken),  .Y4(pc_pe_n),
        .A5(1'b0),        .Y5(),
        .A6(1'b0),        .Y6()
    );

    hc08 u_cond (
        .A1(cond_en),   .B1(cond_sel_n), .Y1(t_uncond),
        .A2(cond_en),   .B2(zero_flag),  .Y2(t_zero),
        .A3(jmp_en),    .B3(cond_result),.Y3(cond_taken),
        .A4(1'b0),      .B4(1'b0),       .Y4()
    );

    // ---- JMP 地址 + 20-bit PC ----
    wire [15:0] jmp_addr = {8'b0, y_reg, udata};
    hc161 u_pc0 (.MR(rst_n), .CP(clk),
        .D0(jmp_addr[0]),  .D1(jmp_addr[1]),  .D2(jmp_addr[2]),  .D3(jmp_addr[3]),
        .Q0(pc0_q[0]), .Q1(pc0_q[1]), .Q2(pc0_q[2]), .Q3(pc0_q[3]),
        .CEP(1'b1), .CET(1'b1), .PE(pc_pe_n), .TC(tc0));
    hc161 u_pc1 (.MR(rst_n), .CP(clk),
        .D0(jmp_addr[4]),  .D1(jmp_addr[5]),  .D2(jmp_addr[6]),  .D3(jmp_addr[7]),
        .Q0(pc1_q[0]), .Q1(pc1_q[1]), .Q2(pc1_q[2]), .Q3(pc1_q[3]),
        .CEP(1'b1), .CET(tc0), .PE(pc_pe_n), .TC(tc1));
    hc161 u_pc2 (.MR(rst_n), .CP(clk),
        .D0(jmp_addr[8]),  .D1(jmp_addr[9]),  .D2(jmp_addr[10]), .D3(jmp_addr[11]),
        .Q0(pc2_q[0]), .Q1(pc2_q[1]), .Q2(pc2_q[2]), .Q3(pc2_q[3]),
        .CEP(1'b1), .CET(tc1), .PE(pc_pe_n), .TC(tc2));
    hc161 u_pc3 (.MR(rst_n), .CP(clk),
        .D0(jmp_addr[12]), .D1(jmp_addr[13]), .D2(jmp_addr[14]), .D3(jmp_addr[15]),
        .Q0(pc3_q[0]), .Q1(pc3_q[1]), .Q2(pc3_q[2]), .Q3(pc3_q[3]),
        .CEP(1'b1), .CET(tc2), .PE(pc_pe_n), .TC(tc3));
    hc161 u_pc4 (.MR(rst_n), .CP(clk),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(pc4_q[0]), .Q1(pc4_q[1]), .Q2(pc4_q[2]), .Q3(pc4_q[3]),
        .CEP(1'b1), .CET(tc3), .PE(pc_pe_n), .TC());
    assign pc = {pc4_q, pc3_q, pc2_q, pc1_q, pc0_q};

    // ---- SRAM 地址 MUX ----
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

    // ---- SRAM ----
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

    // ---- bus MUX ----
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

    // ---- ALU ROM ----
    hc39sf040 #(.INIT_FILE("rom/alu.hex")) u_rom_alu (
        .A0(alu_d[0]),  .A1(alu_d[1]),  .A2(alu_d[2]),  .A3(alu_d[3]),
        .A4(alu_d[4]),  .A5(alu_d[5]),  .A6(alu_d[6]),  .A7(alu_d[7]),
        .A8(ac[0]),      .A9(ac[1]),      .A10(ac[2]),    .A11(ac[3]),
        .A12(ac[4]),     .A13(ac[5]),    .A14(ac[6]),    .A15(ac[7]),
        .A16(alu_op[0]), .A17(alu_op[1]), .A18(alu_op[2]),
        .DQ(alu_result), .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // ---- 寄存器 ----
    hc377 u_ac  (.Enable_bar(ac_dis_n), .D(alu_result), .Clk(clk), .Q(ac));
    hc377 u_x   (.Enable_bar(to_x_n),  .D(alu_result), .Clk(clk), .Q(x_reg));
    hc377 u_y   (.Enable_bar(to_y_n),  .D(alu_result), .Clk(clk), .Q(y_reg));
    hc377 u_out (.Enable_bar(to_out_n),.D(alu_result), .Clk(clk), .Q(out_reg));

    assign DATA_OUT = out_reg;

endmodule
