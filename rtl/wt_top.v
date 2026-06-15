// wt_top.v — 74HC-Chiptune 顶层模块 (全芯片实例化)
//
// 所有存储/锁存都用实例化的 74HC 芯片, 不用 reg 冒充。
// 仿真通过 = 每个芯片模块都被调用 = 每个模块对应 1 片 IC。
//
// 芯片清单 (实例化计数):
//   SPFM 总线  (3): 373, 174, 377     (在 wt_spfm_bus.v)
//   step 计数  (2): 161 ×2
//   指令 ROM   (1): 39SF040
//   参数 RAM   (1): 7134
//   phase 存储 (1): 189
//   相位加法   (1): 283
//   地址 mux   (1): 157 (B 输入选择)
//   累加器锁存 (1): 174
//   phase 缓存 (2): 174 ×2 (nibble 2, nibble 3)
//   vol/wave   (1): 273
//   波表 ROM   (1): 39SF040
//   DAC 输出   (1): 273
//   门电路     (2): 04 + 10 (CLK 门控 + 译码)
//   合计      17 IC

`timescale 1ns/1ps

module wt_top (
    input  wire        STEP_CLK,

    input  wire        SPFM_CLK,
    input  wire        SPFM_RST_n,
    input  wire [7:0]  SPFM_D,
    input  wire        SPFM_A0,
    input  wire        SPFM_CS_n,
    input  wire        SPFM_WR_n,
    input  wire        SPFM_RD_n,

    output wire [7:0]  dac_out
);

    // ============================================================
    // 所有 wire 声明 (避免前向引用问题)
    // ============================================================
    wire [7:0]  reg_addr;
    wire [7:0]  reg_data;
    wire        addr_wr, data_wr;

    wire [3:0] step_lo;
    wire       tc_lo;
    wire       step_hi_q0;
    wire [4:0] step;

    wire [7:0] inst_dq;
    wire       c_adder_clk, c_out_latch, c_param_oe_n;
    wire       c_ram_oe_n, c_rom_oe_n, c_adder_clr_n;
    wire [2:0] c_param_addr;
    wire [1:0] c_voice;

    wire [11:0] addr_R;
    wire [7:0]  do_r;

    wire [3:0] phase_addr;
    wire [3:0] phase_dout;

    wire [3:0] adder_a, adder_b, adder_sum;
    wire       adder_c0, adder_c4;

    wire       accum_clk_gated, dac_clk_gated;

    wire [4:0] accum_q;
    wire       accum_q_4;

    wire       phase_n2_clk, phase_n3_clk;
    wire [3:0] phase_n2, phase_n3;

    wire [7:0] cur_vol_wave;
    wire [3:0] cur_vol;
    wire [2:0] cur_wave;
    wire       volwave_clk;

    wire [7:0] rom_dq;
    wire [7:0] dac_out_w;

    // 派生信号 (纯组合, 不存状态)
    assign step = {step_hi_q0, step_lo};
    wire [18:0] inst_addr = {14'b0, step};
    assign c_adder_clk   = inst_dq[7];
    assign c_out_latch   = inst_dq[6];
    assign c_param_oe_n  = inst_dq[5];
    assign c_ram_oe_n    = inst_dq[4];
    assign c_rom_oe_n    = inst_dq[3];
    assign c_adder_clr_n = inst_dq[2];
    assign c_param_addr  = step[2:0];
    assign c_voice       = step[4:3];

    assign addr_R = {7'b0, c_voice, c_param_addr};
    assign phase_addr = {c_voice, c_param_addr[1:0]};
    assign adder_a = phase_dout;
    assign accum_q_4 = accum_q[4];

    assign cur_vol  = cur_vol_wave[3:0];
    assign cur_wave = cur_vol_wave[6:4];
    assign dac_out  = dac_out_w;

    // ============================================================
    // hc138: param_addr 译码 (1 IC)
    //   输出 Y2_n..Y6_n = param_addr==2..6 (低有效)
    // ============================================================
    wire pe2_n, pe3_n, pe5_n, pe6_n;
    wire pe2, pe3, pe5, pe6;        // 高有效 (经反相)
    wire poe;                        // ~c_param_oe_n

    hc138 u_decoder (
        .A0(c_param_addr[0]), .A1(c_param_addr[1]), .A2(c_param_addr[2]),
        .EA_n(1'b0), .EB_n(1'b0), .E3(1'b1),
        .Y0_n(), .Y1_n(), .Y2_n(pe2_n), .Y3_n(pe3_n),
        .Y4_n(), .Y5_n(pe5_n), .Y6_n(pe6_n), .Y7_n()
    );

    // ============================================================
    // hc04 u_inv1: 反相器 (1 IC, 6 路)
    //   A1=Y2_n       Y1=pe2     A2=Y3_n   Y2=pe3
    //   A3=Y5_n       Y3=pe5     A4=Y6_n   Y4=pe6
    //   A5=c_param_oe_n  Y5=poe  A6=STEP_CLK  Y6=n_step_clk
    // ============================================================
    wire n_step_clk;

    hc04 u_inv1 (
        .A1(pe2_n), .Y1(pe2),
        .A2(pe3_n), .Y2(pe3),
        .A3(pe5_n), .Y3(pe5),
        .A4(pe6_n), .Y4(pe6),
        .A5(c_param_oe_n), .Y5(poe),
        .A6(STEP_CLK), .Y6(n_step_clk)
    );

    // ============================================================
    // hc10 u_gate1: NAND3 × 3 (1 IC)
    //   G1a: STEP, c_adder_clk, 1   → n_accum
    //   G1b: STEP, c_out_latch, 1   → n_dac
    //   G1c: STEP, c_adder_clk, pe2 → n_ph2
    // ============================================================
    wire n_accum, n_dac, n_ph2;

    hc10 u_gate1 (
        .A1(STEP_CLK), .B1(c_adder_clk), .C1(1'b1), .Y1(n_accum),
        .A2(STEP_CLK), .B2(c_out_latch), .C2(1'b1), .Y2(n_dac),
        .A3(STEP_CLK), .B3(c_adder_clk), .C3(pe2),  .Y3(n_ph2)
    );

    // ============================================================
    // hc10 u_gate2: NAND3 × 3 (1 IC)
    //   G2a: STEP, c_adder_clk, pe3 → n_ph3
    //   G2b: STEP, poe, pe5         → n_vw5
    //   G2c: STEP, poe, pe6         → n_vw6
    // ============================================================
    wire n_ph3, n_vw5, n_vw6;

    hc10 u_gate2 (
        .A1(STEP_CLK), .B1(c_adder_clk), .C1(pe3), .Y1(n_ph3),
        .A2(STEP_CLK), .B2(poe),         .C2(pe5), .Y2(n_vw5),
        .A3(STEP_CLK), .B3(poe),         .C3(pe6), .Y3(n_vw6)
    );

    // ============================================================
    // hc10 u_gate3: NAND3 × 3 (1 IC)
    //   G3a: n_vw5, n_vw6, 1   → volwave_clk (OR via DeMorgan, no inv needed)
    //   G3b: c_adder_clr_n, accum_q_4, 1 → n_c0 (反相后给 adder_c0)
    //   G3c: 未用 (输入绑 1)
    // ============================================================
    wire n_c0, n_gate3_unused;

    hc10 u_gate3 (
        .A1(n_vw5),          .B1(n_vw6),          .C1(1'b1),          .Y1(volwave_clk),
        .A2(c_adder_clr_n),  .B2(accum_q_4),      .C2(1'b1),          .Y2(n_c0),
        .A3(1'b1),           .B3(1'b1),           .C3(1'b1),          .Y3(n_gate3_unused)
    );

    // ============================================================
    // hc04 u_inv2: 反相器 (1 IC, 6 路用)
    //   Y1 = ~n_accum = accum_clk_gated
    //   Y2 = ~n_dac   = dac_clk_gated
    //   Y3 = ~n_ph2   = phase_n2_clk
    //   Y4 = ~n_ph3   = phase_n3_clk
    //   Y5 = ~n_c0    = adder_c0
    //   Y6 = 未用 (输入绑 0)
    // ============================================================
    wire inv2_y6_unused;

    hc04 u_inv2 (
        .A1(n_accum), .Y1(accum_clk_gated),
        .A2(n_dac),   .Y2(dac_clk_gated),
        .A3(n_ph2),   .Y3(phase_n2_clk),
        .A4(n_ph3),   .Y4(phase_n3_clk),
        .A5(n_c0),    .Y5(adder_c0),
        .A6(1'b0),    .Y6(inv2_y6_unused)
    );

    // ============================================================
    // SPFM 总线接口 (3 IC: 在 wt_spfm_bus.v)
    // ============================================================
    wt_spfm_bus u_spfm (
        .CLK(SPFM_CLK), .RST_n(SPFM_RST_n),
        .D(SPFM_D), .A0(SPFM_A0),
        .CS_n(SPFM_CS_n), .WR_n(SPFM_WR_n), .RD_n(SPFM_RD_n),
        .reg_addr(reg_addr), .reg_data(reg_data),
        .addr_wr(addr_wr), .data_wr(data_wr)
    );

    // ============================================================
    // hc161 × 2: step[4:0] 计数器 (2 IC)
    // ============================================================
    hc161 u_step_lo (
        .MR(1'b1), .CP(STEP_CLK),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(step_lo[0]), .Q1(step_lo[1]), .Q2(step_lo[2]), .Q3(step_lo[3]),
        .CEP(1'b1), .CET(1'b1), .PE(1'b1), .TC(tc_lo)
    );

    hc161 u_step_hi (
        .MR(1'b1), .CP(STEP_CLK),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(step_hi_q0), .Q1(), .Q2(), .Q3(),
        .CEP(tc_lo), .CET(1'b1), .PE(1'b1), .TC()
    );

    // ============================================================
    // 指令 ROM (1 IC)
    // ============================================================
    hc39sf040 #(.INIT_FILE("rom/rom_instruction.hex")) u_inst (
        .A0(inst_addr[0]),  .A1(inst_addr[1]),  .A2(inst_addr[2]),
        .A3(inst_addr[3]),  .A4(inst_addr[4]),  .A5(inst_addr[5]),
        .A6(inst_addr[6]),  .A7(inst_addr[7]),  .A8(inst_addr[8]),
        .A9(inst_addr[9]),  .A10(inst_addr[10]), .A11(inst_addr[11]),
        .A12(inst_addr[12]), .A13(inst_addr[13]), .A14(inst_addr[14]),
        .A15(inst_addr[15]), .A16(inst_addr[16]), .A17(inst_addr[17]),
        .A18(inst_addr[18]),
        .DQ(inst_dq),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // ============================================================
    // 7134: 参数 RAM (1 IC)
    // ============================================================
    hc7134 u_param (
        .A0L(reg_addr[0]),  .A1L(reg_addr[1]),  .A2L(reg_addr[2]),
        .A3L(reg_addr[3]),  .A4L(reg_addr[4]),  .A5L(reg_addr[5]),
        .A6L(reg_addr[6]),  .A7L(reg_addr[7]),  .A8L(1'b0),
        .A9L(1'b0),  .A10L(1'b0), .A11L(1'b0),
        .DI_L(reg_data), .DO_L(),
        .CE_L_n(~data_wr), .OE_L_n(1'b1), .RW_L(1'b0),
        .A0R(addr_R[0]),  .A1R(addr_R[1]),  .A2R(addr_R[2]),
        .A3R(addr_R[3]),  .A4R(addr_R[4]),  .A5R(addr_R[5]),
        .A6R(addr_R[6]),  .A7R(addr_R[7]),  .A8R(addr_R[8]),
        .A9R(addr_R[9]),  .A10R(addr_R[10]), .A11R(addr_R[11]),
        .DI_R(8'h00), .DO_R(do_r),
        .CE_R_n(c_param_oe_n), .OE_R_n(c_param_oe_n), .RW_R(1'b1)
    );

    // ============================================================
    // hc174: 写地址锁存 (1 IC, 新增 — 解决 189 write race)
    //   CLK = n_step_clk (~STEP_CLK, 上升沿 = STEP 下降沿)
    //   posedge n_step_clk 时 phase_addr 仍是当前 step 的地址
    //   189 写端口用此锁存值, 配合 WE_n=n_accum 在 STEP 下降沿写入
    // ============================================================
    wire [3:0] phase_addr_wr;

    hc174 u_wr_addr (
        .CLR(1'b1),
        .D1(phase_addr[0]), .D2(phase_addr[1]),
        .D3(phase_addr[2]), .D4(phase_addr[3]),
        .D5(1'b0), .D6(1'b0),
        .CLK(n_step_clk),
        .Q1(phase_addr_wr[0]), .Q2(phase_addr_wr[1]),
        .Q3(phase_addr_wr[2]), .Q4(phase_addr_wr[3]),
        .Q5(), .Q6()
    );

    // ============================================================
    // hc189: phase 存储 (1 IC, 16×4 双端口)
    //   读端口: phase_addr (组合, 当前 step 地址)
    //   写端口: phase_addr_wr (锁存, 当前 step 地址)
    //   WE_n = n_accum = ~(STEP & c_adder_clk)
    // ============================================================
    hc189 u_phase (
        .A0_w(phase_addr_wr[0]), .A1_w(phase_addr_wr[1]),
        .A2_w(phase_addr_wr[2]), .A3_w(phase_addr_wr[3]),
        .A0_r(phase_addr[0]), .A1_r(phase_addr[1]),
        .A2_r(phase_addr[2]), .A3_r(phase_addr[3]),
        .D0(adder_sum[0]), .D1(adder_sum[1]), .D2(adder_sum[2]), .D3(adder_sum[3]),
        .O(phase_dout),
        .CS_n(1'b0),
        .WE_n(n_accum)
    );

    // ============================================================
    // hc157: B 输入 mux (1 IC)
    // ============================================================
    hc157 u_addmux (
        .Select(c_param_oe_n),
        .A1(do_r[0]), .B1(1'b0),
        .A2(do_r[1]), .B2(1'b0),
        .A3(do_r[2]), .B3(1'b0),
        .A4(do_r[3]), .B4(1'b0),
        .Enable_n(1'b0),
        .Y1(adder_b[0]), .Y2(adder_b[1]),
        .Y3(adder_b[2]), .Y4(adder_b[3])
    );

    // ============================================================
    // hc283: 4-bit 相位加法器 (1 IC)
    // ============================================================
    hc283 u_adder (
        .A(adder_a), .B(adder_b), .C0(adder_c0),
        .S(adder_sum), .C4(adder_c4)
    );

    // ============================================================
    // hc174: 累加器锁存 (1 IC, 5 D-FF)
    // ============================================================
    hc174 u_accum (
        .CLR(1'b1),
        .D1(adder_sum[0]), .D2(adder_sum[1]), .D3(adder_sum[2]),
        .D4(adder_sum[3]), .D5(adder_c4), .D6(1'b0),
        .CLK(accum_clk_gated),
        .Q1(accum_q[0]), .Q2(accum_q[1]), .Q3(accum_q[2]),
        .Q4(accum_q[3]), .Q5(accum_q[4]), .Q6()
    );

    // ============================================================
    // hc174 × 2: phase 高字节缓存 (2 IC)
    // ============================================================
    hc174 u_phase_lo (
        .CLR(1'b1),
        .D1(accum_q[0]), .D2(accum_q[1]), .D3(accum_q[2]), .D4(accum_q[3]),
        .D5(1'b0), .D6(1'b0),
        .CLK(phase_n2_clk),
        .Q1(phase_n2[0]), .Q2(phase_n2[1]), .Q3(phase_n2[2]), .Q4(phase_n2[3]),
        .Q5(), .Q6()
    );

    hc174 u_phase_hi (
        .CLR(1'b1),
        .D1(accum_q[0]), .D2(accum_q[1]), .D3(accum_q[2]), .D4(accum_q[3]),
        .D5(1'b0), .D6(1'b0),
        .CLK(phase_n3_clk),
        .Q1(phase_n3[0]), .Q2(phase_n3[1]), .Q3(phase_n3[2]), .Q4(phase_n3[3]),
        .Q5(), .Q6()
    );

    // ============================================================
    // hc273: vol/wave 锁存 (1 IC)
    // ============================================================
    ttl_74273 u_volwave (
        .Clear_bar(1'b1),
        .D({1'b0, do_r[2:0], do_r[3:0]}),
        .Clk(volwave_clk),
        .Q(cur_vol_wave)
    );

    // ============================================================
    // 波表 ROM (1 IC)
    //   地址 = {wave[2:0], vol[3:0], phase_n3[3:0], phase_n2[3:0]} = 15 bit
    // ============================================================
    wire [18:0] rom_addr_w = {4'b0, cur_wave, cur_vol, phase_n3, phase_n2};

    hc39sf040 #(.INIT_FILE("rom/rom_wavetable.hex")) u_wavetable (
        .A0(rom_addr_w[0]),  .A1(rom_addr_w[1]),  .A2(rom_addr_w[2]),
        .A3(rom_addr_w[3]),  .A4(rom_addr_w[4]),  .A5(rom_addr_w[5]),
        .A6(rom_addr_w[6]),  .A7(rom_addr_w[7]),  .A8(rom_addr_w[8]),
        .A9(rom_addr_w[9]),  .A10(rom_addr_w[10]), .A11(rom_addr_w[11]),
        .A12(rom_addr_w[12]), .A13(rom_addr_w[13]), .A14(rom_addr_w[14]),
        .A15(rom_addr_w[15]), .A16(rom_addr_w[16]), .A17(rom_addr_w[17]),
        .A18(rom_addr_w[18]),
        .DQ(rom_dq),
        .CE_n(1'b0), .OE_n(c_rom_oe_n), .WE_n(1'b1)
    );

    // ============================================================
    // hc273: DAC 输出锁存 (1 IC)
    // ============================================================
    ttl_74273 u_dac (
        .Clear_bar(1'b1),
        .D(rom_dq),
        .Clk(dac_clk_gated),
        .Q(dac_out_w)
    );

    // 抑制未使用信号警告 (这些控制位当前未驱动外部逻辑, 留作扩展)
    wire _unused = &{addr_wr, c_ram_oe_n, n_gate3_unused, inv2_y6_unused, 1'b0};

endmodule
