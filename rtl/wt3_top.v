// wt3_top.v — 74HC-Chiptune WT3 顶层模块 (3通道波表合成器)
//
// 芯片清单:
//   SPFM 总线  (3): 138, 373, 377
//   step 计数  (1): 161 (5-bit, 32步)
//   微码 ROM   (2): 39SF040 ×2 (16-bit 控制字)
//   参数 RAM#1 (1): 62256 (phase_acc 存储)
//   参数 RAM#2 (1): 62256 (phase_step + wave/vol)
//   相位加法   (2): 283 ×2 (8-bit 加法)
//   数据锁存   (2): 377 ×2 (RAM 输出锁存)
//   进位锁存   (1): 74HC74 (carry FF)
//   波表 ROM   (1): 39SF040
//   DAC 输出   (1): 273
//   地址 mux   (1): 157 (RAM 地址选择: 微码 vs SPFM)
//   反相器     (1): 04
//   合计: 20 IC

`timescale 1ns/1ps

module wt3_top (
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
    // Wire declarations
    // ============================================================

    // SPFM bus
    wire [7:0] reg_addr;
    wire [7:0] reg_data;
    wire       addr_wr_n, data_wr_n;

    // Step counter
    wire [4:0] step;

    // Microcode ROM output (16-bit control word)
    wire [15:0] ucode;
    wire  p1_oe_n, p2_oe_n, p1_we_n, p2_we_n;
    wire  rom_oe_n, latch_273_n, latch_carry, c0_force0;
    wire [7:0] mc_ram_addr;

    // RAM address mux output
    wire [7:0] ram_addr;

    // RAM data
    wire [7:0] p1_do, p2_do;

    // Latched RAM outputs
    wire [7:0] reg_a_q, reg_b_q;

    // Adder
    wire [3:0] adder_lo_s, adder_hi_s;
    wire       adder_lo_c4, adder_hi_c4;
    wire       adder_lo_c0, adder_hi_c0;

    // Carry latch
    wire       carry_q, carry_q_n;

    // SPFM write data to RAM#2
    wire       spfm_we_n;

    // Wavetable ROM address components
    wire [1:0] cur_wave;
    wire [3:0] cur_vol;
    wire [7:0] rom_dq;

    // DAC
    wire [7:0] dac_out_w;

    // ============================================================
    // Microcode decode (combinational from ucode[15:0])
    // ============================================================
    assign p1_oe_n      = ucode[15];
    assign p2_oe_n      = ucode[14];
    assign p1_we_n      = ucode[13];
    assign p2_we_n      = ucode[12];
    assign rom_oe_n     = ucode[11];
    assign latch_273_n = ucode[10];
    assign latch_carry = ucode[9];
    assign c0_force0   = ucode[8];
    assign mc_ram_addr  = ucode[7:0];

    // Adder C0:
    //   Lo 283: C0=0 during low byte (c0_force0), carry latch during high byte
    //   Hi 283: always cascaded from lo 283 C4
    assign adder_lo_c0 = c0_force0 ? 1'b0 : carry_q;
    assign adder_hi_c0 = adder_lo_c4;

    // SPFM write to RAM#2: active when data_wr_n=0 (writing data)
    assign spfm_we_n = data_wr_n;

    // ============================================================
    // RAM address mux: microcode vs SPFM
    //   Select = data_wr_n (0=SPFM write, 1=microcode)
    // ============================================================
    wire ram_sel = data_wr_n;

    hc157 u_addr_mux (
        .Select(ram_sel),
        .A1(mc_ram_addr[0]), .B1(reg_addr[0]),
        .A2(mc_ram_addr[1]), .B2(reg_addr[1]),
        .A3(mc_ram_addr[2]), .B3(reg_addr[2]),
        .A4(mc_ram_addr[3]), .B4(reg_addr[3]),
        .Enable_n(1'b0),
        .Y1(ram_addr[0]), .Y2(ram_addr[1]),
        .Y3(ram_addr[2]), .Y4(ram_addr[3])
    );
    // Upper 4 bits: SPFM reg_addr[7:4] for writes, mc_ram_addr[7:4] otherwise
    assign ram_addr[7:4] = ram_sel ? mc_ram_addr[7:4] : reg_addr[7:4];

    // ============================================================
    // 7404: inverters (1 IC)
    //   Y1 = ~p1_we_n    → p1_we (active-high, for 377 latch)
    //   Y2 = ~p2_oe_n    → p2_oe (active-high, for 377 latch)
    //   Y3 = ~p1_oe_n    → p1_oe (active-high, for 377 latch)
    //   Y4 = ~latch_carry → carry_clk (negative edge latch)
    //   Y5-Y6: unused
    // ============================================================
    wire p1_oe, p2_oe, p1_we;
    wire unused_inv5, unused_inv6;

    hc04 u_inv (
        .A1(p1_we_n),    .Y1(p1_we),
        .A2(p2_oe_n),    .Y2(p2_oe),
        .A3(p1_oe_n),    .Y3(p1_oe),
        .A4(latch_carry),.Y4(),  // carry latch uses posedge latch_carry
        .A5(1'b0),       .Y5(unused_inv5),
        .A6(1'b0),       .Y6(unused_inv6)
    );

    // ============================================================
    // SPFM bus interface: 138 译码 + 373 锁存 + 377 地址寄存器
    //   138: {CS_n, WR_n, A0} → Y0=addr_wr, Y1=data_wr
    //   373: D 透明锁存 (le=Y0|Y1, CS=0&WR=0 时透明)
    //   377: 地址寄存器 (posedge SPFM_CLK, Y0=0 时锁存)
    // ============================================================
    wire spfm_le = ~(SPFM_CS_n | SPFM_WR_n);  // CS=0 & WR=0 时 le=1 (透明)
    reg [7:0] d_latched = 8'h00;
    wire spfm_138_y0, spfm_138_y1;

    // 373 透明锁存: le=1 时 Q 跟随 D, le=0 时保持
    always @(*) begin
        if (spfm_le) d_latched = SPFM_D;
    end

    // 138 译码: A={CS_n, WR_n, A0}, E=SPFM_RST_n
    hc138 u_spfm_138 (
        .A0(SPFM_A0), .A1(SPFM_WR_n), .A2(SPFM_CS_n),
        .EA_n(1'b0), .EB_n(1'b0), .E3(SPFM_RST_n),
        .Y0_n(spfm_138_y0), .Y1_n(spfm_138_y1),
        .Y2_n(), .Y3_n(), .Y4_n(), .Y5_n(), .Y6_n(), .Y7_n()
    );
    // Y0=0: CS=0,WR=0,A0=0 → 写地址
    // Y1=0: CS=0,WR=0,A0=1 → 写数据

    // 377 地址寄存器: posedge CLK, Y0=0 时锁存
    hc377 u_spfm_addr_reg (
        .Enable_bar(spfm_138_y0),
        .D(d_latched),
        .Clk(SPFM_CLK),
        .Q(reg_addr)
    );

    assign reg_data  = d_latched;
    assign addr_wr_n = spfm_138_y0;
    assign data_wr_n = spfm_138_y1;

    // ============================================================
    // 161: 5-bit step counter (32 steps)
    // ============================================================
    wire tc_lo;
    wire [3:0] step_lo;
    wire step_hi;

    hc161 u_step_lo (
        .MR(1'b1), .CP(STEP_CLK),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(step_lo[0]), .Q1(step_lo[1]), .Q2(step_lo[2]), .Q3(step_lo[3]),
        .CEP(1'b1), .CET(1'b1), .PE(1'b1), .TC(tc_lo)
    );

    hc161 u_step_hi (
        .MR(1'b1), .CP(STEP_CLK),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(step_hi), .Q1(), .Q2(), .Q3(),
        .CEP(tc_lo), .CET(1'b1), .PE(1'b1), .TC()
    );

    assign step = {step_hi, step_lo};

    // ============================================================
    // Microcode ROM (2 × 39SF040, 16-bit)
    // ============================================================
    wire [18:0] mc_addr = {14'b0, step};
    wire [7:0] mc_lo_dq, mc_hi_dq;

    hc39sf040 #(.INIT_FILE("rom/wt3_microcode_lo.hex")) u_mc_lo (
        .A0(mc_addr[0]),  .A1(mc_addr[1]),  .A2(mc_addr[2]),
        .A3(mc_addr[3]),  .A4(mc_addr[4]),  .A5(mc_addr[5]),
        .A6(mc_addr[6]),  .A7(mc_addr[7]),  .A8(mc_addr[8]),
        .A9(mc_addr[9]),  .A10(mc_addr[10]), .A11(mc_addr[11]),
        .A12(mc_addr[12]), .A13(mc_addr[13]), .A14(mc_addr[14]),
        .A15(mc_addr[15]), .A16(mc_addr[16]), .A17(mc_addr[17]),
        .A18(mc_addr[18]),
        .DQ(mc_lo_dq),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    hc39sf040 #(.INIT_FILE("rom/wt3_microcode_hi.hex")) u_mc_hi (
        .A0(mc_addr[0]),  .A1(mc_addr[1]),  .A2(mc_addr[2]),
        .A3(mc_addr[3]),  .A4(mc_addr[4]),  .A5(mc_addr[5]),
        .A6(mc_addr[6]),  .A7(mc_addr[7]),  .A8(mc_addr[8]),
        .A9(mc_addr[9]),  .A10(mc_addr[10]), .A11(mc_addr[11]),
        .A12(mc_addr[12]), .A13(mc_addr[13]), .A14(mc_addr[14]),
        .A15(mc_addr[15]), .A16(mc_addr[16]), .A17(mc_addr[17]),
        .A18(mc_addr[18]),
        .DQ(mc_hi_dq),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    assign ucode = {mc_hi_dq, mc_lo_dq};

    // ============================================================
    // RAM#1 (62256): phase_acc storage
    //   Read: microcode p1_oe_n controls OE
    //   Write: microcode p1_we_n controls WE
    //   Address: ram_addr from mux
    //   DI: adder sum (from two 283)
    // ============================================================
    wire [14:0] p1_addr = {7'b0, ram_addr};

    hc62256 u_ram1 (
        .A0(ram_addr[0]),  .A1(ram_addr[1]),  .A2(ram_addr[2]),
        .A3(ram_addr[3]),  .A4(ram_addr[4]),  .A5(ram_addr[5]),
        .A6(ram_addr[6]),  .A7(ram_addr[7]),
        .A8(1'b0), .A9(1'b0), .A10(1'b0), .A11(1'b0),
        .A12(1'b0), .A13(1'b0), .A14(1'b0),
        .DI({adder_hi_s, adder_lo_s}),
        .DO(p1_do),
        .CE_n(1'b0), .OE_n(p1_oe_n), .WE_n(p1_we_n)
    );

    // ============================================================
    // RAM#2 (62256): phase_step + wave_idx/vol
    //   Read: microcode p2_oe_n controls OE
    //   Write: SPFM bus (spfm_we_n) OR microcode p2_we_n
    //   Address: ram_addr from mux
    //   DI: SPFM reg_data
    // ============================================================
    // WE = active when either SPFM writes or microcode writes
    wire p2_we_combined = spfm_we_n & p2_we_n;  // active-low OR (NOR): write when either is 0

    hc62256 u_ram2 (
        .A0(ram_addr[0]),  .A1(ram_addr[1]),  .A2(ram_addr[2]),
        .A3(ram_addr[3]),  .A4(ram_addr[4]),  .A5(ram_addr[5]),
        .A6(ram_addr[6]),  .A7(ram_addr[7]),
        .A8(1'b0), .A9(1'b0), .A10(1'b0), .A11(1'b0),
        .A12(1'b0), .A13(1'b0), .A14(1'b0),
        .DI(reg_data),
        .DO(p2_do),
        .CE_n(1'b0), .OE_n(p2_oe_n), .WE_n(p2_we_combined)
    );

    // ============================================================
    // 377 #1: Latch RAM#1 output (phase_acc read)
    //   CLK = STEP_CLK, Enable = p1_oe (active-high)
    // ============================================================
    hc377 u_reg_a (
        .Enable_bar(~p1_oe),
        .D(p1_do),
        .Clk(STEP_CLK),
        .Q(reg_a_q)
    );

    // ============================================================
    // 377 #2: Latch RAM#2 output (phase_step / wave_vol read)
    //   CLK = STEP_CLK, Enable = p2_oe (active-high)
    // ============================================================
    hc377 u_reg_b (
        .Enable_bar(~p2_oe),
        .D(p2_do),
        .Clk(STEP_CLK),
        .Q(reg_b_q)
    );

    // ============================================================
    // 283 ×2: 8-bit adder (two 4-bit adders)
    //   Lo: reg_a[3:0] + reg_b[3:0] + C0
    //   Hi: reg_a[7:4] + reg_b[7:4] + C4_lo
    // ============================================================
    hc283 u_adder_lo (
        .A(reg_a_q[3:0]),
        .B(reg_b_q[3:0]),
        .C0(adder_lo_c0),
        .S(adder_lo_s),
        .C4(adder_lo_c4)
    );

    hc283 u_adder_hi (
        .A(reg_a_q[7:4]),
        .B(reg_b_q[7:4]),
        .C0(adder_lo_c4),
        .S(adder_hi_s),
        .C4(adder_hi_c4)
    );

    // ============================================================
    // HC74: carry flip-flop (1 of 2 FFs used)
    //   D = adder_hi_c4, CLK = latch_carry (posedge)
    //   PRE1=1, CLR1=1
    // ============================================================
    hc74 u_carry (
        .CLR1(1'b1), .CLK1(latch_carry), .D1(adder_hi_c4), .PRE1(1'b1),
        .Q1(carry_q), .Q1_n(carry_q_n),
        .CLR2(1'b1), .CLK2(1'b0), .D2(1'b0), .PRE2(1'b1),
        .Q2(), .Q2_n()
    );

    // ============================================================
    // Wave/vol extraction from reg_b_q (latched on sub 6)
    //   reg_b_q[1:0] = wave_idx, reg_b_q[5:2] = vol
    // ============================================================
    assign cur_wave = reg_b_q[1:0];
    assign cur_vol  = reg_b_q[5:2];

    // ============================================================
    // Wavetable ROM (1 × 39SF040)
    //   Address: {4'b0, wave[1:0], vol[3:0], phase[6:0]}
    //   phase comes from reg_a_q[6:0] (latched phase_acc[6:0])
    //   On sub 7: rom_oe_n=0, ROM outputs sample, latch_273_n=0 latches DAC
    // ============================================================
    wire [18:0] wt_addr = {4'b0, cur_wave, cur_vol, reg_a_q[6:0]};

    hc39sf040 #(.INIT_FILE("rom/wt3_wavetable.hex")) u_wavetable (
        .A0(wt_addr[0]),  .A1(wt_addr[1]),  .A2(wt_addr[2]),
        .A3(wt_addr[3]),  .A4(wt_addr[4]),  .A5(wt_addr[5]),
        .A6(wt_addr[6]),  .A7(wt_addr[7]),  .A8(wt_addr[8]),
        .A9(wt_addr[9]),  .A10(wt_addr[10]), .A11(wt_addr[11]),
        .A12(wt_addr[12]), .A13(wt_addr[13]), .A14(wt_addr[14]),
        .A15(wt_addr[15]), .A16(wt_addr[16]), .A17(wt_addr[17]),
        .A18(wt_addr[18]),
        .DQ(rom_dq),
        .CE_n(1'b0), .OE_n(rom_oe_n), .WE_n(1'b1)
    );

    // ============================================================
    // 273: DAC output latch
    //   Clk = ~latch_273_n (active-high clock when latch_273_n=0)
    // ============================================================
    wire dac_clk = ~latch_273_n;

    ttl_74273 u_dac (
        .Clear_bar(1'b1),
        .D(rom_dq),
        .Clk(dac_clk),
        .Q(dac_out_w)
    );

    assign dac_out = dac_out_w;

    // ============================================================
    // Unused signal suppression
    // ============================================================
    wire _unused = &{addr_wr_n, carry_q_n, adder_hi_c4,
                     adder_hi_c0, unused_inv5, unused_inv6, 1'b0};

endmodule
