// cpu39040.v — 39040cpu: ROM-ALU TTL 处理器
//
// 时序: 2 分频, phase=0 取指+锁存ctrl/d_reg+PC+1, phase=1 执行+锁存寄存器
//   gated_clk = clk & ~phase → 只在 phase=0 时锁存 ctrl/d_reg
//   寄存器 377 只在 phase=1 时使能
//
// 指令 (ROM1): INS[7:5]|MOD[4:2]|BUS[1:0]
//   INS: 0=LD 1=AND 2=OR 3=XOR 4=ADD 5=SUB 6=ST 7=JMP
//   MOD: 0=[D] 1=[X] 2=[Y] 3=[Y+X] 4→X 5→Y 6→OUT 7=[Y+X],X++
//   BUS: 0=D 1=RAM 2=AC 3=IN

`timescale 1ns/1ps

module cpu39040 (
    input  wire        CLK,
    input  wire        RST_n,
    input  wire [7:0]  EXT_IN,
    output wire [7:0]  DATA_OUT,
    output wire        PLAYING
);

    wire clk   = CLK;
    wire rst_n = RST_n;

    // ============================================================
    // 2 分频相位 (74HC174 D1=Q1 反馈)
    // ============================================================
    wire phase;
    hc174 u_phase (
        .CLR(1'b1),
        .D1(~phase), .D2(1'b0), .D3(1'b0),
        .D4(1'b0),   .D5(1'b0), .D6(1'b0),
        .CLK(clk),
        .Q1(phase), .Q2(), .Q3(), .Q4(), .Q5(), .Q6()
    );

    // ============================================================
    // 74HC04 — 反相器 (预留)
    // ============================================================
    wire inv_unused;
    hc04 u_inv (
        .A1(1'b0), .Y1(inv_unused),
        .A2(1'b0), .Y2(),
        .A3(1'b0), .Y3(),
        .A4(1'b0), .Y4(),
        .A5(1'b0), .Y5(),
        .A6(1'b0), .Y6()
    );

    // ============================================================
    // 20-bit PC: 5× 74HC161 (CET 级联, phase=0 时计数)
    // ============================================================
    wire [3:0] pc0_q, pc1_q, pc2_q, pc3_q, pc4_q;
    wire       tc0, tc1, tc2, tc3;
    wire       pc_ce = ~phase;

    hc161 u_pc0 (
        .MR(rst_n), .CP(clk),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(pc0_q[0]), .Q1(pc0_q[1]), .Q2(pc0_q[2]), .Q3(pc0_q[3]),
        .CEP(pc_ce), .CET(pc_ce), .PE(1'b1), .TC(tc0)
    );
    hc161 u_pc1 (
        .MR(rst_n), .CP(clk),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(pc1_q[0]), .Q1(pc1_q[1]), .Q2(pc1_q[2]), .Q3(pc1_q[3]),
        .CEP(pc_ce), .CET(tc0), .PE(1'b1), .TC(tc1)
    );
    hc161 u_pc2 (
        .MR(rst_n), .CP(clk),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(pc2_q[0]), .Q1(pc2_q[1]), .Q2(pc2_q[2]), .Q3(pc2_q[3]),
        .CEP(pc_ce), .CET(tc1), .PE(1'b1), .TC(tc2)
    );
    hc161 u_pc3 (
        .MR(rst_n), .CP(clk),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(pc3_q[0]), .Q1(pc3_q[1]), .Q2(pc3_q[2]), .Q3(pc3_q[3]),
        .CEP(pc_ce), .CET(tc2), .PE(1'b1), .TC(tc3)
    );
    hc161 u_pc4 (
        .MR(rst_n), .CP(clk),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(pc4_q[0]), .Q1(pc4_q[1]), .Q2(pc4_q[2]), .Q3(pc4_q[3]),
        .CEP(pc_ce), .CET(tc3), .PE(1'b1), .TC()
    );

    wire [19:0] pc = {pc4_q, pc3_q, pc2_q, pc1_q, pc0_q};

    // ============================================================
    // ROM1: 控制字
    // ============================================================
    wire [7:0] rom1_dq;

    hc39sf040 #(.INIT_FILE("rom39040/ctrl.hex")) u_rom1 (
        .A0(pc[0]),   .A1(pc[1]),  .A2(pc[2]),  .A3(pc[3]),
        .A4(pc[4]),   .A5(pc[5]),  .A6(pc[6]),  .A7(pc[7]),
        .A8(pc[8]),   .A9(pc[9]),  .A10(pc[10]), .A11(pc[11]),
        .A12(pc[12]), .A13(pc[13]), .A14(pc[14]), .A15(pc[15]),
        .A16(pc[16]), .A17(pc[17]), .A18(pc[18]),
        .DQ(rom1_dq),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // gated clock: 只在 phase=0 的 CLK 上升沿产生上升沿
    wire gated_clk = clk & ~phase;

    wire [7:0] ctrl;
    hc273 #(.WIDTH(8)) u_ctrl_latch (
        .MR_n(rst_n), .CP(gated_clk),
        .D(rom1_dq), .Q(ctrl)
    );

    wire [2:0] ins     = ctrl[7:5];
    wire [2:0] mod     = ctrl[4:2];
    wire [1:0] bus_sel = ctrl[1:0];

    // ============================================================
    // ROM2: 数据 D
    // ============================================================
    wire [7:0] rom2_dq;

    hc39sf040 #(.INIT_FILE("rom39040/data.hex")) u_rom2 (
        .A0(pc[0]),   .A1(pc[1]),  .A2(pc[2]),  .A3(pc[3]),
        .A4(pc[4]),   .A5(pc[5]),  .A6(pc[6]),  .A7(pc[7]),
        .A8(pc[8]),   .A9(pc[9]),  .A10(pc[10]), .A11(pc[11]),
        .A12(pc[12]), .A13(pc[13]), .A14(pc[14]), .A15(pc[15]),
        .A16(pc[16]), .A17(pc[17]), .A18(pc[18]),
        .DQ(rom2_dq),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    wire [7:0] d_reg;
    hc273 #(.WIDTH(8)) u_d_latch (
        .MR_n(rst_n), .CP(gated_clk),
        .D(rom2_dq), .Q(d_reg)
    );

    // ============================================================
    // 使能解码 (声明在前)
    // ============================================================
    wire is_st  = (ins == 3'b110);
    wire is_jmp = (ins == 3'b111);

    wire to_ac  = !is_st && !is_jmp &&
                  (mod == 3'b000 || mod == 3'b001 ||
                   mod == 3'b010 || mod == 3'b011 || mod == 3'b111);
    wire to_x   = !is_st && !is_jmp && (mod == 3'b100);
    wire to_y   = !is_st && !is_jmp && (mod == 3'b101);
    wire to_out = !is_st && !is_jmp && (mod == 3'b110);

    // ============================================================
    // 寄存器声明在前 (wire, 用于后续引用)
    // ============================================================
    wire [7:0] ac;
    wire [7:0] x_reg;
    wire [7:0] y_reg;
    wire [7:0] out_reg;
    wire [7:0] alu_result;

    // ============================================================
    // 总线 MUX
    // ============================================================
    wire [7:0] ram_do;
    wire [7:0] bus_data;

    assign bus_data = (bus_sel == 2'b00) ? d_reg  :
                      (bus_sel == 2'b01) ? ram_do :
                      (bus_sel == 2'b10) ? ac     :
                      EXT_IN;

    // ============================================================
    // 地址生成
    // ============================================================
    wire use_x = mod[0];
    wire use_y = mod[1] | mod[2];

    wire [7:0] mem_lo = use_x ? x_reg : d_reg;
    wire [7:0] mem_hi = use_y ? y_reg : 8'b0;
    wire [15:0] mem_addr = {mem_hi, mem_lo};

    // ============================================================
    // HM628512 SRAM
    // ============================================================
    wire ram_we_n = is_st ? 1'b0 : 1'b1;

    hc628512 u_ram (
        .A0(mem_addr[0]),  .A1(mem_addr[1]),  .A2(mem_addr[2]),
        .A3(mem_addr[3]),  .A4(mem_addr[4]),  .A5(mem_addr[5]),
        .A6(mem_addr[6]),  .A7(mem_addr[7]),  .A8(mem_addr[8]),
        .A9(mem_addr[9]),  .A10(mem_addr[10]), .A11(mem_addr[11]),
        .A12(mem_addr[12]), .A13(mem_addr[13]), .A14(mem_addr[14]),
        .A15(mem_addr[15]), .A16(1'b0), .A17(1'b0), .A18(1'b0),
        .DI(bus_data),
        .DO(ram_do),
        .CS_n(1'b0), .OE_n(1'b0), .WE_n(ram_we_n)
    );

    // ============================================================
    // ROM3: ALU 查表
    // ============================================================
    hc39sf040 #(.INIT_FILE("rom39040/alu.hex")) u_rom3 (
        .A0(bus_data[0]),  .A1(bus_data[1]),  .A2(bus_data[2]),
        .A3(bus_data[3]),  .A4(bus_data[4]),  .A5(bus_data[5]),
        .A6(bus_data[6]),  .A7(bus_data[7]),
        .A8(ac[0]),  .A9(ac[1]),  .A10(ac[2]), .A11(ac[3]),
        .A12(ac[4]), .A13(ac[5]), .A14(ac[6]), .A15(ac[7]),
        .A16(ins[0]), .A17(ins[1]), .A18(ins[2]),
        .DQ(alu_result),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // ============================================================
    // 寄存器实例化 (声明在前, 实例在后)
    // 只在 phase=1 时锁存
    // ============================================================
    hc377 u_ac (
        .Enable_bar(~(to_ac & phase)),
        .D(alu_result), .Clk(clk), .Q(ac)
    );

    wire x_inc = (mod == 3'b111) && !is_st && !is_jmp;
    wire [7:0] x_next = x_reg + 8'b1;
    wire [7:0] x_load = x_inc ? x_next : alu_result;
    wire x_en = (to_x | x_inc) & phase;

    hc377 u_x (
        .Enable_bar(~x_en),
        .D(x_load), .Clk(clk), .Q(x_reg)
    );

    hc377 u_y (
        .Enable_bar(~(to_y & phase)),
        .D(alu_result), .Clk(clk), .Q(y_reg)
    );

    hc377 u_out (
        .Enable_bar(~(to_out & phase)),
        .D(alu_result), .Clk(clk), .Q(out_reg)
    );

    // ============================================================
    // 输出
    // ============================================================
    assign DATA_OUT = out_reg;
    assign PLAYING  = (pc != 20'b0);

endmodule
