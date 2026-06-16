// cpu39040.v — 39040cpu: ROM-ALU TTL 处理器
//
// 时序: PC 每 CLK +1, 每条指令 2 周期
//   奇数 PC (pc[0]=1): 取指 — 锁存 ctrl, d_reg (273 gated by pc[0]&clk)
//   偶数 PC (pc[0]=0): 执行 — 锁存 AC/X/Y/OUT (377 gated by ~pc[0])
//   ROM 地址 = PC >> 1 (每条指令占 2 个 PC 值)
//
// 指令 (ROM1): INS[7:5]|MOD[4:2]|BUS[1:0]
//   INS: 0=LD 1=AND 2=OR 3=XOR 4=ADD 5=SUB 6=ST 7=JMP/Bcc
//   MOD (非JMP): 0=[D] 1=[X] 2=[Y] 3=[Y+X] 4→X 5→Y 6→OUT 7=[Y+X],X++
//   MOD (JMP): 0=far({Y,bus}) 1-7: 条件分支 (bit0=carry,bit1=zero,bit2=neg)
//   BUS: 0=D 1=RAM 2=AC 3=IN
//
// 芯片: 5×161, 4×377, 3×39SF040, 1×628512, 2×273, 1×174, 1×04

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
    // 74HC04 — 反相器
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
    reg        jmp_flag_reg;
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

    // Phase: ROM addr = PC>>1 gives same word for both halves of instruction
    assign fetch_phase = pc[0];   // pc 奇数 = 取指
    assign exec_phase  = ~pc[0];  // pc 偶数 = 执行
    assign rom_addr    = pc[19:1]; // ROM 地址 = PC>>1

    // 使能解码
    assign is_st  = (ins == 3'b110);
    assign is_jmp = (ins == 3'b111);

    assign to_ac  = !is_st && !is_jmp &&
                      (mod == 3'b000 || mod == 3'b001 ||
                       mod == 3'b010 || mod == 3'b011 || mod == 3'b111);
    assign to_x   = !is_st && !is_jmp && (mod == 3'b100);
    assign to_y   = !is_st && !is_jmp && (mod == 3'b101);
    assign to_out = !is_st && !is_jmp && (mod == 3'b110);

    // 总线 MUX
    assign bus_data = (bus_sel == 2'b00) ? d_reg  :
                      (bus_sel == 2'b01) ? ram_do :
                      (bus_sel == 2'b10) ? ac     :
                      EXT_IN;

    // 地址生成
    assign use_x   = mod[0];
    assign use_y   = mod[1] | mod[2];
    assign mem_lo = use_x ? x_reg : d_reg;
    assign mem_hi = use_y ? y_reg : 8'b0;
    assign mem_addr = {mem_hi, mem_lo};

    // RAM 控制
    assign ram_we_n = is_st ? 1'b0 : 1'b1;

    // JMP 条件 — 组合逻辑, 不含 phase
    assign zero_flag  = (ac == 8'b0);
    assign neg_flag   = ac[7];
    assign carry_flag = (ins == 3'b100) ? (alu_result < bus_data) :
                       (ins == 3'b101) ? (ac < bus_data) : 1'b0;

    assign cond_taken = is_jmp & (
        (mod == 3'b000) |
        (mod[0] & carry_flag) |
        (mod[1] & zero_flag) |
        (mod[2] & neg_flag)
    );

    assign is_far = (mod == 3'b000);
    // Near jump: d_reg = ROM addr (instruction index), PC = (index << 1) | 1
    //   OR low bit to start in fetch phase (pc[0]=1), avoiding phantom exec
    // Far jump:  {y_reg, bus_data}, also ensure low bit = 1
    assign jmp_target = is_far ?
        {y_reg, bus_data[7:1], 1'b1} : {pc[15:8], bus_data, 1'b1};

    assign jmp_addr_full = {jmp_hi3, jmp_hi2, jmp_hi1, jmp_hi0,
                            jmp_mid[3:0], jmp_lo};

    // pc_pe_n: 在 exec_phase 的 clk 上升沿, cond_taken 为真时 PE 有效
    // cond_taken 在 exec_phase 整个期间为真, 所以在 exec→fetch 边沿
    // (pc[0] 0→1), new exec_phase=0, 但 OLD cond_taken 仍通过
    // registered flag 传递: jmp_flag_reg 在 exec 期间被置 1
    // 关键: 用 negedge clk 捕获 exec_phase 结束前的 cond_taken
    assign pc_pe_n = ~jmp_flag_reg;

    // X 自增
    assign x_inc  = (mod == 3'b111) && !is_st && !is_jmp;
    assign x_next = x_reg + 8'b1;
    assign x_load = x_inc ? x_next : alu_result;
    assign x_en   = (to_x | x_inc) & exec_phase;

    // 输出
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

    assign ins     = ctrl[7:5];
    assign mod     = ctrl[4:2];
    assign bus_sel = ctrl[1:0];

    // ============================================================
    // ROM2: 数据 D
    // ============================================================
    wire [7:0] rom2_dq;

    hc39sf040 #(.INIT_FILE("rom39040/data.hex")) u_rom2 (
        .A0(rom_addr[0]),  .A1(rom_addr[1]),  .A2(rom_addr[2]),
        .A3(rom_addr[3]),  .A4(rom_addr[4]),  .A5(rom_addr[5]),
        .A6(rom_addr[6]),  .A7(rom_addr[7]),
        .A8(rom_addr[8]),  .A9(rom_addr[9]), .A10(rom_addr[10]),
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
    // 寄存器
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
    // JMP flag — negedge 捕获 exec 阶段条件, posedge 触发 161 PE
    // ============================================================
    // 时序: exec 阶段 pc[0]=0, 在 negedge clk 时 exec_phase 仍为 1
    // → jmp_flag_reg 置 1. 下一个 posedge clk 时 pc_pe_n=0, 161 PE 加载跳转地址.
    // 进入 fetch 阶段后的 negedge 清除 flag.
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n)
            jmp_flag_reg <= 1'b0;
        else if (exec_phase)
            jmp_flag_reg <= cond_taken;
        else
            jmp_flag_reg <= 1'b0;
    end

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
