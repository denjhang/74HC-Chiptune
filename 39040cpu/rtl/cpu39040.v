// cpu39040.v — 39040cpu: ROM-ALU TTL 处理器 (全芯片实例化)
//
// 时序: PC 每 CLK +1, 每条指令 2 周期
//   奇数 PC (pc[0]=1): 取指 — 锁存 ctrl, d_reg (273, 每CLK)
//   偶数 PC (pc[0]=0): 执行 — 锁存 AC/X/Y/OUT (377, exec_phase)
//   ROM 地址 = PC >> 1 (每条指令占 2 个 PC 值)
//
// 指令 (ROM1): INS[7:5]|MOD[4:2]|BUS[1:0]
//   INS: 0=LD 1=AND 2=OR 3=XOR 4=ADD 5=SUB 6=ST 7=JMP/Bcc
//   MOD (非JMP): 0=[D] 1=[X] 2=[Y] 3=[Y+X] 4→X 5→Y 6→OUT 7=[Y+X],X++
//   MOD (JMP): 0=far({Y,bus}) 1-7: 条件分支 (bit0=carry,bit1=zero,bit2=neg)
//   BUS: 0=D 1=RAM 2=AC 3=IN
//
// 芯片清单:
//   5×161    — 20-bit PC 计数器
//   4×377    — AC, X, Y, OUT 寄存器
//   3×39SF040 — ROM1(ctrl), ROM2(data), ROM3(ALU)
//   1×628512  — SRAM
//   5×273    — ctrl latch, d_reg latch, jmp flag(1), jmp_lo, jmp_mid
//   1×174    — jmp address high bits
//   1×04     — 反相器 (clk_inv + exec_phase + pc_pe_n)
//  10×157    — bus MUX(6), mem_lo(2), mem_hi(2)
//   1×08     — jmp flag AND gate
//   合计 26 片

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
    // 全部 wire 前向声明
    // ============================================================
    wire [3:0] pc0_q, pc1_q, pc2_q, pc3_q, pc4_q;
    wire [19:0] pc;
    wire       tc0, tc1, tc2, tc3;

    wire [7:0] ctrl, d_reg, ac, x_reg, y_reg, out_reg;
    wire [7:0] alu_result, bus_data, ram_do;
    wire [2:0] ins, mod;
    wire [1:0] bus_sel;
    wire       is_st, is_jmp;
    wire       fetch_phase, exec_phase;
    wire [18:0] rom_addr;
    wire       pc_pe_n;
    wire       zero_flag, neg_flag, carry_flag;
    wire       cond_taken;
    wire       is_far;
    wire [15:0] jmp_addr_full;
    wire [16:0] jmp_target;
    wire       jmp_flag_reg;
    wire [7:0] jmp_lo, jmp_mid;
    wire       jmp_hi3, jmp_hi2, jmp_hi1, jmp_hi0;
    wire       use_x, use_y;
    wire [7:0] mem_lo, mem_hi;
    wire [15:0] mem_addr;
    wire       ram_we_n;
    wire       to_ac, to_x, to_y, to_out;
    wire       x_inc;
    wire [7:0] x_next, x_load;
    wire       x_en;

    // 总线 MUX 中间连线
    wire [3:0] bus_s1a_lo, bus_s1a_hi;
    wire [3:0] bus_s1b_lo, bus_s1b_hi;

    // jmp_flag 相关
    wire       clk_inv;
    wire       jf_d;

    // ============================================================
    // 74HC04 #1 — 反相器 (clk_inv + exec_phase)
    // ============================================================
    hc04 u_inv1 (
        .A1(clk),          .Y1(clk_inv),
        .A2(pc[0]),        .Y2(exec_phase),
        .A3(1'b0),         .Y3(),
        .A4(1'b0),         .Y4(),
        .A5(1'b0),         .Y5(),
        .A6(1'b0),         .Y6()
    );

    assign fetch_phase = pc[0];
    assign rom_addr    = pc[19:1];

    // ============================================================
    // 74HC04 #2 — 反相器 (pc_pe_n = ~jmp_flag_reg)
    // ============================================================
    hc04 u_inv2 (
        .A1(jmp_flag_reg), .Y1(pc_pe_n),
        .A2(1'b0),         .Y2(),
        .A3(1'b0),         .Y3(),
        .A4(1'b0),         .Y4(),
        .A5(1'b0),         .Y5(),
        .A6(1'b0),         .Y6()
    );

    // ============================================================
    // ROM 输出解码
    // ============================================================
    assign ins     = ctrl[7:5];
    assign mod     = ctrl[4:2];
    assign bus_sel = ctrl[1:0];

    // is_st / is_jmp — behavioral (纯组合解码, 无时序影响)
    assign is_st  = (ins == 3'b110);
    assign is_jmp = (ins == 3'b111);

    // ============================================================
    // 寄存器使能解码 — behavioral (纯组合解码, 无时序影响)
    // ============================================================
    assign to_ac  = !is_st && !is_jmp &&
                      (mod == 3'b000 || mod == 3'b001 ||
                       mod == 3'b010 || mod == 3'b011 || mod == 3'b111);
    assign to_x   = !is_st && !is_jmp && (mod == 3'b100);
    assign to_y   = !is_st && !is_jmp && (mod == 3'b101);
    assign to_out = !is_st && !is_jmp && (mod == 3'b110);

    // ============================================================
    // bus_data 4:1 MUX — 6× 74HC157 (两级树)
    //   Stage 1a: bus_sel[0] 选 d_reg(0) / ram_do(1)
    //   Stage 1b: bus_sel[0] 选 ac(0)     / EXT_IN(1)
    //   Stage 2:  bus_sel[1] 选 stage1a(0) / stage1b(1)
    // ============================================================

    // Stage 1a: {d_reg, ram_do} pair
    hc157 u_bus_s1a_lo (
        .Select(bus_sel[0]),
        .A1(d_reg[0]),  .B1(ram_do[0]),
        .A2(d_reg[1]),  .B2(ram_do[1]),
        .A3(d_reg[2]),  .B3(ram_do[2]),
        .A4(d_reg[3]),  .B4(ram_do[3]),
        .Enable_n(1'b0),
        .Y1(bus_s1a_lo[0]), .Y2(bus_s1a_lo[1]),
        .Y3(bus_s1a_lo[2]), .Y4(bus_s1a_lo[3])
    );

    hc157 u_bus_s1a_hi (
        .Select(bus_sel[0]),
        .A1(d_reg[4]),  .B1(ram_do[4]),
        .A2(d_reg[5]),  .B2(ram_do[5]),
        .A3(d_reg[6]),  .B3(ram_do[6]),
        .A4(d_reg[7]),  .B4(ram_do[7]),
        .Enable_n(1'b0),
        .Y1(bus_s1a_hi[0]), .Y2(bus_s1a_hi[1]),
        .Y3(bus_s1a_hi[2]), .Y4(bus_s1a_hi[3])
    );

    // Stage 1b: {ac, EXT_IN} pair
    hc157 u_bus_s1b_lo (
        .Select(bus_sel[0]),
        .A1(ac[0]),     .B1(EXT_IN[0]),
        .A2(ac[1]),     .B2(EXT_IN[1]),
        .A3(ac[2]),     .B3(EXT_IN[2]),
        .A4(ac[3]),     .B4(EXT_IN[3]),
        .Enable_n(1'b0),
        .Y1(bus_s1b_lo[0]), .Y2(bus_s1b_lo[1]),
        .Y3(bus_s1b_lo[2]), .Y4(bus_s1b_lo[3])
    );

    hc157 u_bus_s1b_hi (
        .Select(bus_sel[0]),
        .A1(ac[4]),     .B1(EXT_IN[4]),
        .A2(ac[5]),     .B2(EXT_IN[5]),
        .A3(ac[6]),     .B3(EXT_IN[6]),
        .A4(ac[7]),     .B4(EXT_IN[7]),
        .Enable_n(1'b0),
        .Y1(bus_s1b_hi[0]), .Y2(bus_s1b_hi[1]),
        .Y3(bus_s1b_hi[2]), .Y4(bus_s1b_hi[3])
    );

    // Stage 2: bus_sel[1] selects stage1a(0) / stage1b(1)
    hc157 u_bus_s2_lo (
        .Select(bus_sel[1]),
        .A1(bus_s1a_lo[0]), .B1(bus_s1b_lo[0]),
        .A2(bus_s1a_lo[1]), .B2(bus_s1b_lo[1]),
        .A3(bus_s1a_lo[2]), .B3(bus_s1b_lo[2]),
        .A4(bus_s1a_lo[3]), .B4(bus_s1b_lo[3]),
        .Enable_n(1'b0),
        .Y1(bus_data[0]), .Y2(bus_data[1]),
        .Y3(bus_data[2]), .Y4(bus_data[3])
    );

    hc157 u_bus_s2_hi (
        .Select(bus_sel[1]),
        .A1(bus_s1a_hi[0]), .B1(bus_s1b_hi[0]),
        .A2(bus_s1a_hi[1]), .B2(bus_s1b_hi[1]),
        .A3(bus_s1a_hi[2]), .B3(bus_s1b_hi[2]),
        .A4(bus_s1a_hi[3]), .B4(bus_s1b_hi[3]),
        .Enable_n(1'b0),
        .Y1(bus_data[4]), .Y2(bus_data[5]),
        .Y3(bus_data[6]), .Y4(bus_data[7])
    );

    // ============================================================
    // mem_addr 生成 — mem_lo + mem_hi MUX
    //   mem_lo = use_x ? x_reg : d_reg   (2:1, use_x=mod[0])
    //   mem_hi = use_y ? y_reg : 8'b0    (2:1, use_y=mod[1]|mod[2])
    // ============================================================
    assign use_x = mod[0];
    assign use_y = mod[1] | mod[2];

    // mem_lo: 1× hc157 (4-bit, 低4位和高4位分两个芯片)
    //   实际上 8-bit 需要 2× 157. 但 mem_lo[3:0] 用一个, mem_hi[3:0] 用另一个
    //   Select 不同 (use_x vs use_y), 所以不能合并
    hc157 u_mem_lo (
        .Select(use_x),
        .A1(d_reg[0]), .B1(x_reg[0]),
        .A2(d_reg[1]), .B2(x_reg[1]),
        .A3(d_reg[2]), .B3(x_reg[2]),
        .A4(d_reg[3]), .B4(x_reg[3]),
        .Enable_n(1'b0),
        .Y1(mem_lo[0]), .Y2(mem_lo[1]),
        .Y3(mem_lo[2]), .Y4(mem_lo[3])
    );

    hc157 u_mem_lo_hi (
        .Select(use_x),
        .A1(d_reg[4]), .B1(x_reg[4]),
        .A2(d_reg[5]), .B2(x_reg[5]),
        .A3(d_reg[6]), .B3(x_reg[6]),
        .A4(d_reg[7]), .B4(x_reg[7]),
        .Enable_n(1'b0),
        .Y1(mem_lo[4]), .Y2(mem_lo[5]),
        .Y3(mem_lo[6]), .Y4(mem_lo[7])
    );

    // mem_hi: A=GND, B=y_reg, Select=use_y
    hc157 u_mem_hi (
        .Select(use_y),
        .A1(1'b0),    .B1(y_reg[0]),
        .A2(1'b0),    .B2(y_reg[1]),
        .A3(1'b0),    .B3(y_reg[2]),
        .A4(1'b0),    .B4(y_reg[3]),
        .Enable_n(1'b0),
        .Y1(mem_hi[0]), .Y2(mem_hi[1]),
        .Y3(mem_hi[2]), .Y4(mem_hi[3])
    );

    hc157 u_mem_hi_hi (
        .Select(use_y),
        .A1(1'b0),    .B1(y_reg[4]),
        .A2(1'b0),    .B2(y_reg[5]),
        .A3(1'b0),    .B3(y_reg[6]),
        .A4(1'b0),    .B4(y_reg[7]),
        .Enable_n(1'b0),
        .Y1(mem_hi[4]), .Y2(mem_hi[5]),
        .Y3(mem_hi[6]), .Y4(mem_hi[7])
    );

    assign mem_addr = {mem_hi, mem_lo};

    // ============================================================
    // RAM 控制 — ram_we_n
    //   ram_we_n = is_st ? 0 : 1  → 直接用 is_st_inv
    // ============================================================
    assign ram_we_n = ~is_st;

    // ============================================================
    // carry_flag — 2× hc85 级联 8-bit 比较
    //   ADD carry:  alu_result < bus_data  (无符号, 溢出)
    //   SUB borrow: ac < bus_data         (无符号, 借位)
    //   通用: carry = (ins==ADD & alu<bus) | (ins==SUB & ac<bus)
    // ============================================================

    // carry_flag — behavioral (ADD: alu_result<bus, SUB: ac<bus)
    assign carry_flag = (ins == 3'b100) ? (alu_result < bus_data) :
                        (ins == 3'b101) ? (ac < bus_data) : 1'b0;

    // zero_flag / neg_flag
    assign zero_flag = (ac == 8'b0);
    assign neg_flag  = ac[7];

    // cond_taken — behavioral (纯组合解码, 无时序影响)
    assign is_far = ~(mod[0] | mod[1] | mod[2]);
    assign cond_taken = is_jmp & (is_far | (mod[0] & carry_flag) |
                                  (mod[1] & zero_flag) | (mod[2] & neg_flag));

    // 4 个条件项的 AND
    wire carry_term, zero_term, neg_term;
    // ============================================================
    // jmp_target — behavioral (纯地址拼接选择, 无时序影响)
    //   near: {pc[15:8], bus_data, 1'b1} = 17-bit
    //   far:  {y_reg, bus_data[7:1], 1'b1} = 17-bit
    // ============================================================
    assign jmp_target = is_far ? {y_reg, bus_data[7:1], 1'b1}
                                 : {pc[15:8], bus_data, 1'b1};

    assign jmp_addr_full = {jmp_hi3, jmp_hi2, jmp_hi1, jmp_hi0,
                            jmp_mid[3:0], jmp_lo};

    // ============================================================
    // X 自增 + MUX
    // ============================================================
    assign x_inc  = (mod == 3'b111) && !is_st && !is_jmp;
    assign x_en   = (to_x | x_inc) & exec_phase;
    assign x_next = x_reg + 8'd1;

    // x_load MUX: x_inc ? x_next : alu_result → 2× hc157
    hc157 u_x_load_lo (
        .Select(x_inc),
        .A1(alu_result[0]), .B1(x_next[0]),
        .A2(alu_result[1]), .B2(x_next[1]),
        .A3(alu_result[2]), .B3(x_next[2]),
        .A4(alu_result[3]), .B4(x_next[3]),
        .Enable_n(1'b0),
        .Y1(x_load[0]), .Y2(x_load[1]),
        .Y3(x_load[2]), .Y4(x_load[3])
    );

    hc157 u_x_load_hi (
        .Select(x_inc),
        .A1(alu_result[4]), .B1(x_next[4]),
        .A2(alu_result[5]), .B2(x_next[5]),
        .A3(alu_result[6]), .B3(x_next[6]),
        .A4(alu_result[7]), .B4(x_next[7]),
        .Enable_n(1'b0),
        .Y1(x_load[4]), .Y2(x_load[5]),
        .Y3(x_load[6]), .Y4(x_load[7])
    );

    // ============================================================
    // 输出
    // ============================================================
    assign DATA_OUT = out_reg;
    assign PLAYING  = (pc != 20'b0);

    // ============================================================
    // 20-bit PC: 5× 74HC161
    // ============================================================
    hc161 u_pc0 (
        .MR(rst_n), .CP(clk),
        .D0(jmp_addr_full[0]),  .D1(jmp_addr_full[1]),
        .D2(jmp_addr_full[2]),  .D3(jmp_addr_full[3]),
        .Q0(pc0_q[0]), .Q1(pc0_q[1]), .Q2(pc0_q[2]), .Q3(pc0_q[3]),
        .CEP(1'b1), .CET(1'b1), .PE(pc_pe_n), .TC(tc0)
    );
    hc161 u_pc1 (
        .MR(rst_n), .CP(clk),
        .D0(jmp_addr_full[4]),  .D1(jmp_addr_full[5]),
        .D2(jmp_addr_full[6]),  .D3(jmp_addr_full[7]),
        .Q0(pc1_q[0]), .Q1(pc1_q[1]), .Q2(pc1_q[2]), .Q3(pc1_q[3]),
        .CEP(1'b1), .CET(tc0), .PE(pc_pe_n), .TC(tc1)
    );
    hc161 u_pc2 (
        .MR(rst_n), .CP(clk),
        .D0(jmp_addr_full[8]),  .D1(jmp_addr_full[9]),
        .D2(jmp_addr_full[10]), .D3(jmp_addr_full[11]),
        .Q0(pc2_q[0]), .Q1(pc2_q[1]), .Q2(pc2_q[2]), .Q3(pc2_q[3]),
        .CEP(1'b1), .CET(tc1), .PE(pc_pe_n), .TC(tc2)
    );
    hc161 u_pc3 (
        .MR(rst_n), .CP(clk),
        .D0(jmp_addr_full[12]), .D1(jmp_addr_full[13]),
        .D2(jmp_addr_full[14]), .D3(jmp_addr_full[15]),
        .Q0(pc3_q[0]), .Q1(pc3_q[1]), .Q2(pc3_q[2]), .Q3(pc3_q[3]),
        .CEP(1'b1), .CET(tc2), .PE(pc_pe_n), .TC(tc3)
    );
    hc161 u_pc4 (
        .MR(rst_n), .CP(clk),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(pc4_q[0]), .Q1(pc4_q[1]), .Q2(pc4_q[2]), .Q3(pc4_q[3]),
        .CEP(1'b1), .CET(tc3), .PE(pc_pe_n), .TC()
    );

    assign pc = {pc4_q, pc3_q, pc2_q, pc1_q, pc0_q};

    // ============================================================
    // ROM1: 控制字
    // ============================================================
    wire [7:0] rom1_dq;

    hc39sf040 #(.INIT_FILE("rom39040/ctrl.hex")) u_rom1 (
        .A0(rom_addr[0]),  .A1(rom_addr[1]),  .A2(rom_addr[2]),
        .A3(rom_addr[3]),  .A4(rom_addr[4]),  .A5(rom_addr[5]),
        .A6(rom_addr[6]),  .A7(rom_addr[7]),
        .A8(rom_addr[8]),  .A9(rom_addr[9]),  .A10(rom_addr[10]),
        .A11(rom_addr[11]), .A12(rom_addr[12]), .A13(rom_addr[13]),
        .A14(rom_addr[14]), .A15(rom_addr[15]), .A16(rom_addr[16]),
        .A17(rom_addr[17]), .A18(rom_addr[18]),
        .DQ(rom1_dq),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    hc273 #(.WIDTH(8)) u_ctrl_latch (
        .MR_n(rst_n), .CP(clk),
        .D(rom1_dq), .Q(ctrl)
    );

    // ============================================================
    // ROM2: 数据 D
    // ============================================================
    wire [7:0] rom2_dq;

    hc39sf040 #(.INIT_FILE("rom39040/data.hex")) u_rom2 (
        .A0(rom_addr[0]),  .A1(rom_addr[1]),  .A2(rom_addr[2]),
        .A3(rom_addr[3]),  .A4(rom_addr[4]),  .A5(rom_addr[5]),
        .A6(rom_addr[6]),  .A7(rom_addr[7]),
        .A8(rom_addr[8]),  .A9(rom_addr[9]),  .A10(rom_addr[10]),
        .A11(rom_addr[11]), .A12(rom_addr[12]), .A13(rom_addr[13]),
        .A14(rom_addr[14]), .A15(rom_addr[15]), .A16(rom_addr[16]),
        .A17(rom_addr[17]), .A18(rom_addr[18]),
        .DQ(rom2_dq),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    hc273 #(.WIDTH(8)) u_d_latch (
        .MR_n(rst_n), .CP(clk),
        .D(rom2_dq), .Q(d_reg)
    );

    // ============================================================
    // HM628512 SRAM
    // ============================================================
    hc628512 u_ram (
        .A0(mem_addr[0]),  .A1(mem_addr[1]),  .A2(mem_addr[2]),
        .A3(mem_addr[3]),  .A4(mem_addr[4]),  .A5(mem_addr[5]),
        .A6(mem_addr[6]),  .A7(mem_addr[7]), .A8(mem_addr[8]),
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
    // 寄存器 — 4× 74HC377
    // ============================================================
    hc377 u_ac (
        .Enable_bar(~(to_ac & exec_phase)),
        .D(alu_result), .Clk(clk), .Q(ac)
    );

    hc377 u_x (
        .Enable_bar(~x_en),
        .D(x_load), .Clk(clk), .Q(x_reg)
    );

    hc377 u_y (
        .Enable_bar(~(to_y & exec_phase)),
        .D(alu_result), .Clk(clk), .Q(y_reg)
    );

    hc377 u_out (
        .Enable_bar(~(to_out & exec_phase)),
        .D(alu_result), .Clk(clk), .Q(out_reg)
    );

    // ============================================================
    // JMP flag — hc08 AND + hc273(negedge clk)
    //   clk_inv via hc04, D = exec_phase & cond_taken via hc08
    // ============================================================
    hc08 u_jmp_and (
        .A1(exec_phase), .B1(cond_taken), .Y1(jf_d),
        .A2(1'b0),        .B2(1'b0),        .Y2(),
        .A3(1'b0),        .B3(1'b0),        .Y3(),
        .A4(1'b0),        .B4(1'b0),        .Y4()
    );

    hc273 #(.WIDTH(1)) u_jmp_flag (
        .MR_n(rst_n),
        .CP(clk_inv),
        .D(jf_d),
        .Q(jmp_flag_reg)
    );

    // ============================================================
    // 跳转地址锁存
    // ============================================================
    hc174 u_jmp_hi (
        .CLR(rst_n),
        .D1(1'b0), .D2(jmp_target[15]), .D3(jmp_target[14]),
        .D4(jmp_target[13]), .D5(jmp_target[12]), .D6(1'b0),
        .CLK(clk),
        .Q1(), .Q2(jmp_hi3), .Q3(jmp_hi2),
        .Q4(jmp_hi1), .Q5(jmp_hi0), .Q6()
    );

    hc273 #(.WIDTH(8)) u_jmp_lo (
        .MR_n(rst_n), .CP(clk),
        .D(jmp_target[7:0]), .Q(jmp_lo)
    );

    hc273 #(.WIDTH(8)) u_jmp_mid (
        .MR_n(rst_n), .CP(clk),
        .D({4'b0, jmp_target[11:8]}), .Q(jmp_mid)
    );

endmodule
