// wt3_core.v — v1.4: 16-bit 相位精度, 4 通道 TDM
//
// 芯片清单 (25 IC):
//   SPFM 总线  (3): 373 (透明锁存) + 174 (同步器) + 377 (SPFM 地址寄存器)
//   数据锁存  (5): 377×5 (reg_a_lo + reg_a_hi + reg_b_lo + reg_b_hi + reg_c)
//   step 计数  (2): 161×2 (级联, 6-bit, 64步)
//   微码 ROM   (1): 39SF040 (8-bit 控制字)
//   wavetable ROM (1): 39SF040 (8-bit 波形数据, 地址 = reg_a[15:8] + reg_c[3:0])
//   地址 mux   (5): 157×5 (RAM 地址低 4 / 高 4 / DI 低 4 / DI 高 4 / WE+OE)
//   DI lo/hi mux (1): 157×1 (writeback 时选 adder_lo vs adder_hi)
//   译码器     (1): 154 (step[3:0] → latch/dac_clk 硬译码)
//   参数 RAM   (1): 62256 (32K×8, 用 32B: 4ch × 8B)
//   加法器     (4): 283×4 (16-bit 级联)
//   输出锁存   (1): 273 (DAC 输出, TDM 4 通道共享)
//
// RAM 布局 (每通道 8 字节, 5-bit 地址 = {ch[5:4], sub_addr[2:0]}):
//   ch0: RAM[0]=acc_lo, RAM[1]=acc_hi, RAM[2]=step_lo, RAM[3]=step_hi, RAM[4]=vol
//   ch1: RAM[8..12]
//   ch2: RAM[16..20]
//   ch3: RAM[24..28]
//
// 微码 ROM 8-bit 控制字:
//   bit 7: ram_oe_n      (0=read RAM)
//   bit 6: ram_we_n      (0=write RAM)
//   bit 5-3: reserved
//   bit 2-0: ram_sub_addr (3-bit: 0=acc_lo, 1=acc_hi, 2=step_lo, 3=step_hi, 4=vol)
//
// 154 硬译码 (step[3:0] → 低有效):
//   step=1  → Y1  = latch_a_lo_n
//   step=3  → Y3  = latch_a_hi_n
//   step=5  → Y5  = latch_b_lo_n
//   step=7  → Y7  = latch_b_hi_n
//   step=9  → Y9  = latch_c_n
//   step=12 → Y12 = ~dac_clk (反相后送 273 CP)
//
// 频率公式: freq = phase_step × 48000 / 65536 = phase_step × 0.732 Hz
//   C4 (261.63 Hz) → phase_step = 0x0165
//   A4 (440.00 Hz) → phase_step = 0x0259

`timescale 1ns/1ps

module wt3_core (
    input  wire        STEP_CLK,

    input  wire        SPFM_CLK,
    input  wire        SPFM_RST_n,
    input  wire [7:0]  SPFM_D,
    input  wire        SPFM_A0,
    input  wire        SPFM_CS_n,
    input  wire        SPFM_WR_n,
    input  wire        SPFM_RD_n,

    output wire [15:0] reg_a_q,     // 16-bit phase_acc
    output wire [15:0] reg_b_q,     // 16-bit phase_step
    output wire [7:0]  reg_c_q,     // 8-bit volume
    output wire [15:0] adder_s,     // 16-bit adder output
    output wire [7:0]  dac_out,     // 8-bit DAC output
    output wire [1:0]  cur_channel, // step[5:4]
    output wire [3:0]  cur_substep, // step[3:0]
    output wire        latch_dac    // 273 CP (154 Y12 反相, step=12 时上升沿)
);

    // ============================================================
    // Wire declarations
    // ============================================================
    wire [7:0] reg_addr;
    wire [7:0] reg_data;
    wire       addr_wr_pulse_n;
    wire       data_wr_pulse_n;

    wire [5:0] step;

    wire [7:0] ucode;
    wire       ram_oe_n_mc;
    wire       mc_we_n;
    wire [2:0] mc_ram_sub_addr;

    wire [7:0] ram_addr;
    wire [7:0] ram_do;
    wire       ram_oe_n;
    wire       ram_we_n;
    wire [7:0] ram_di;

    wire [7:0] wave_do;

    // ============================================================
    // Microcode decode (8-bit, v1.4)
    // ============================================================
    assign ram_oe_n_mc   = ucode[7];
    assign mc_we_n       = ucode[6];
    assign mc_ram_sub_addr = ucode[2:0];
    assign cur_channel = step[5:4];
    assign cur_substep = step[3:0];

    // RAM 地址 = {step[5:4] (通道号), mc_ram_sub_addr (通道内偏移)}, 5-bit
    wire [4:0] mc_ram_addr_full = {step[5:4], mc_ram_sub_addr};

    // ============================================================
    // 154: step[3:0] 硬译码 latch/dac_clk
    // ============================================================
    wire [15:0] decode_y;
    // SPFM 写期间 (CS_n=0) 或复位期间 (RST_n=0) 禁止 latch/dac
    wire decode_disable = ~SPFM_RST_n | ~SPFM_CS_n;

    hc154 u_decode (
        .A({step[3], step[2], step[1], step[0]}),
        .G_n(decode_disable),
        .Y(decode_y)
    );

    wire latch_a_lo_n = decode_y[1];   // step=1
    wire latch_a_hi_n = decode_y[3];   // step=3
    wire latch_b_lo_n = decode_y[5];   // step=5
    wire latch_b_hi_n = decode_y[7];   // step=7
    wire latch_c_n    = decode_y[9];   // step=9
    wire dac_clk_n    = decode_y[13];  // step=13 (低有效)

    // ============================================================
    // 74HC04 — 六反相器 (1 片, 用 1 路: dac_clk_n → latch_dac)
    //   反相 154 Y13 (低有效) 为上升沿, 送 U_dac (273) CP
    // 其余 5 路未用, 接 GND
    // (spfm_bus 内还有 1 片 hc04, 处理 addr_q3/data_q2 反相)
    // ============================================================
    hc04 u_inv (
        .A1(dac_clk_n), .Y1(latch_dac),
        .A2(1'b0),      .Y2(),
        .A3(1'b0),      .Y3(),
        .A4(1'b0),      .Y4(),
        .A5(1'b0),      .Y5(),
        .A6(1'b0),      .Y6()
    );

    // ============================================================
    // 157 #1: RAM 地址 mux 低 4 位
    //   Select=0 (SPFM) → reg_addr[3:0]
    //   Select=1 (微码) → mc_ram_addr_full[3:0]
    // ============================================================
    wire mux1_y0, mux1_y1, mux1_y2, mux1_y3;

    hc157 u_addr_lo (
        .Select(SPFM_CS_n),
        .A1(reg_addr[0]),     .B1(mc_ram_addr_full[0]),
        .A2(reg_addr[1]),     .B2(mc_ram_addr_full[1]),
        .A3(reg_addr[2]),     .B3(mc_ram_addr_full[2]),
        .A4(reg_addr[3]),     .B4(mc_ram_addr_full[3]),
        .Enable_n(1'b0),
        .Y1(mux1_y0), .Y2(mux1_y1),
        .Y3(mux1_y2), .Y4(mux1_y3)
    );

    assign ram_addr[0] = mux1_y0;
    assign ram_addr[1] = mux1_y1;
    assign ram_addr[2] = mux1_y2;
    assign ram_addr[3] = mux1_y3;

    // ============================================================
    // 157 #2: RAM 地址高 4 位
    //   Select=0 (SPFM) → reg_addr[7:4]
    //   Select=1 (微码) → {3'b0, mc_ram_addr_full[4]}
    // ============================================================
    hc157 u_addr_hi (
        .Select(SPFM_CS_n),
        .A1(reg_addr[4]),     .B1(mc_ram_addr_full[4]),
        .A2(reg_addr[5]),     .B2(1'b0),
        .A3(reg_addr[6]),     .B3(1'b0),
        .A4(reg_addr[7]),     .B4(1'b0),
        .Enable_n(1'b0),
        .Y1(ram_addr[4]),
        .Y2(ram_addr[5]),
        .Y3(ram_addr[6]),
        .Y4(ram_addr[7])
    );

    // ============================================================
    // 157 #3: RAM DI 低 4 位
    //   Select=0 (SPFM) → reg_data[3:0]
    //   Select=1 (微码) → writeback_data[3:0]
    // ============================================================
    wire [7:0] writeback_data;
    wire [3:0] di_lo;
    wire [3:0] wb_lo;
    assign wb_lo = writeback_data[3:0];

    hc157 u_di_lo (
        .Select(SPFM_CS_n),
        .A1(reg_data[0]),     .B1(wb_lo[0]),
        .A2(reg_data[1]),     .B2(wb_lo[1]),
        .A3(reg_data[2]),     .B3(wb_lo[2]),
        .A4(reg_data[3]),     .B4(wb_lo[3]),
        .Enable_n(1'b0),
        .Y1(di_lo[0]), .Y2(di_lo[1]),
        .Y3(di_lo[2]), .Y4(di_lo[3])
    );

    // ============================================================
    // 157 #4: RAM DI 高 4 位
    //   Select=0 (SPFM) → reg_data[7:4]
    //   Select=1 (微码) → writeback_data[7:4]
    // ============================================================
    wire [3:0] di_hi;
    wire [3:0] wb_hi;
    assign wb_hi = writeback_data[7:4];

    hc157 u_di_hi (
        .Select(SPFM_CS_n),
        .A1(reg_data[4]),     .B1(wb_hi[0]),
        .A2(reg_data[5]),     .B2(wb_hi[1]),
        .A3(reg_data[6]),     .B3(wb_hi[2]),
        .A4(reg_data[7]),     .B4(wb_hi[3]),
        .Enable_n(1'b0),
        .Y1(di_hi[0]), .Y2(di_hi[1]),
        .Y3(di_hi[2]), .Y4(di_hi[3])
    );

    assign ram_di = {di_hi, di_lo};

    // ============================================================
    // 157 #5: WE 选择 + OE 选择 (2 路用, 2 路空)
    //   Y1 = ram_we_n:  Select=0→data_wr_pulse_n, Select=1→mc_we_n
    //   Y2 = ram_oe_n:  Select=0→1 (SPFM 时 OE 关), Select=1→ram_oe_n_mc
    // ============================================================
    hc157 u_we_oe_mux (
        .Select(SPFM_CS_n),
        .A1(data_wr_pulse_n), .B1(mc_we_n),
        .A2(1'b1),            .B2(ram_oe_n_mc),
        .A3(1'b0),            .B3(1'b0),
        .A4(1'b0),            .B4(1'b0),
        .Enable_n(1'b0),
        .Y1(ram_we_n),
        .Y2(ram_oe_n),
        .Y3(), .Y4()
    );

    // ============================================================
    // 157 #6: writeback DI lo/hi mux
    //   Select=mc_ram_sub_addr[0] (0=acc_lo→adder_lo, 1=acc_hi→adder_hi)
    // ============================================================
    wire [7:0] adder_lo;
    wire [7:0] adder_hi;
    wire [3:0] wb_lo_mux, wb_hi_mux;

    hc157 u_wb_mux (
        .Select(mc_ram_sub_addr[0]),
        .A1(adder_lo[0]), .B1(adder_hi[0]),
        .A2(adder_lo[1]), .B2(adder_hi[1]),
        .A3(adder_lo[2]), .B3(adder_hi[2]),
        .A4(adder_lo[3]), .B4(adder_hi[3]),
        .Enable_n(1'b0),
        .Y1(wb_lo_mux[0]), .Y2(wb_lo_mux[1]),
        .Y3(wb_lo_mux[2]), .Y4(wb_lo_mux[3])
    );

    // wb_mux 高 4 位
    wire [3:0] wb_hi_out;
    hc157 u_wb_mux_hi (
        .Select(mc_ram_sub_addr[0]),
        .A1(adder_lo[4]), .B1(adder_hi[4]),
        .A2(adder_lo[5]), .B2(adder_hi[5]),
        .A3(adder_lo[6]), .B3(adder_hi[6]),
        .A4(adder_lo[7]), .B4(adder_hi[7]),
        .Enable_n(1'b0),
        .Y1(wb_hi_out[0]), .Y2(wb_hi_out[1]),
        .Y3(wb_hi_out[2]), .Y4(wb_hi_out[3])
    );

    assign writeback_data = {wb_hi_out, wb_lo_mux};

    // ============================================================
    // SPFM 总线 (3 IC: 373, 174, 377) + 1 IC (74HC04 反相器)
    // ============================================================
    wt3_spfm_bus u_spfm (
        .CLK(SPFM_CLK), .RST_n(SPFM_RST_n),
        .D(SPFM_D), .A0(SPFM_A0),
        .CS_n(SPFM_CS_n), .WR_n(SPFM_WR_n), .RD_n(SPFM_RD_n),
        .reg_addr(reg_addr), .reg_data(reg_data),
        .addr_wr_pulse_n(addr_wr_pulse_n),
        .data_wr_pulse_n(data_wr_pulse_n)
    );

    // ============================================================
    // 161 ×2: 6-bit step counter (64 steps)
    // ============================================================
    wire tc_lo;
    wire [3:0] step_lo;
    wire [1:0] step_hi;

    hc161 u_step_lo (
        .MR(1'b1), .CP(STEP_CLK),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(step_lo[0]), .Q1(step_lo[1]),
        .Q2(step_lo[2]), .Q3(step_lo[3]),
        .CEP(SPFM_RST_n), .CET(SPFM_RST_n), .PE(1'b1), .TC(tc_lo)
    );

    hc161 u_step_hi (
        .MR(1'b1), .CP(STEP_CLK),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(step_hi[0]), .Q1(step_hi[1]), .Q2(), .Q3(),
        .CEP(tc_lo & SPFM_RST_n), .CET(SPFM_RST_n), .PE(1'b1), .TC()
    );

    assign step = {step_hi, step_lo};

    // ============================================================
    // 微码 ROM (1 × 39SF040, 8-bit)
    // ============================================================
    wire [18:0] mc_addr = {13'b0, step};

    hc39sf040 #(.INIT_FILE("rom/wt3_microcode.hex")) u_mc (
        .A0(mc_addr[0]),  .A1(mc_addr[1]),  .A2(mc_addr[2]),
        .A3(mc_addr[3]),  .A4(mc_addr[4]),  .A5(mc_addr[5]),
        .A6(1'b0), .A7(1'b0),  .A8(1'b0), .A9(1'b0),
        .A10(1'b0), .A11(1'b0), .A12(1'b0), .A13(1'b0),
        .A14(1'b0), .A15(1'b0), .A16(1'b0), .A17(1'b0),
        .A18(1'b0),
        .DQ(ucode),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // ============================================================
    // 62256: 参数 RAM
    // ============================================================
    hc62256 u_ram (
        .A0(ram_addr[0]),  .A1(ram_addr[1]),
        .A2(ram_addr[2]),  .A3(ram_addr[3]),
        .A4(ram_addr[4]),  .A5(ram_addr[5]),
        .A6(ram_addr[6]),  .A7(ram_addr[7]),
        .A8(1'b0), .A9(1'b0), .A10(1'b0), .A11(1'b0),
        .A12(1'b0), .A13(1'b0), .A14(1'b0),
        .DI(ram_di),
        .DO(ram_do),
        .CE_n(1'b0),
        .OE_n(ram_oe_n),
        .WE_n(ram_we_n)
    );

    // ============================================================
    // 377 reg_a_lo: 锁存 phase_acc 低字节
    // ============================================================
    hc377 u_reg_a_lo (
        .Enable_bar(latch_a_lo_n),
        .D(ram_do),
        .Clk(STEP_CLK),
        .Q(reg_a_q[7:0])
    );

    // ============================================================
    // 377 reg_a_hi: 锁存 phase_acc 高字节
    // ============================================================
    hc377 u_reg_a_hi (
        .Enable_bar(latch_a_hi_n),
        .D(ram_do),
        .Clk(STEP_CLK),
        .Q(reg_a_q[15:8])
    );

    // ============================================================
    // 377 reg_b_lo: 锁存 phase_step 低字节
    // ============================================================
    hc377 u_reg_b_lo (
        .Enable_bar(latch_b_lo_n),
        .D(ram_do),
        .Clk(STEP_CLK),
        .Q(reg_b_q[7:0])
    );

    // ============================================================
    // 377 reg_b_hi: 锁存 phase_step 高字节
    // ============================================================
    hc377 u_reg_b_hi (
        .Enable_bar(latch_b_hi_n),
        .D(ram_do),
        .Clk(STEP_CLK),
        .Q(reg_b_q[15:8])
    );

    // ============================================================
    // 377 reg_c: 锁存 volume (低 4 位有效)
    // ============================================================
    hc377 u_reg_c (
        .Enable_bar(latch_c_n),
        .D(ram_do),
        .Clk(STEP_CLK),
        .Q(reg_c_q)
    );

    // ============================================================
    // 283 ×4: 16-bit 全加器
    //   #1: A=reg_a[3:0], B=reg_b[3:0], C0=0
    //   #2: A=reg_a[7:4], B=reg_b[7:4], C0=C4_#1
    //   #3: A=reg_a[11:8], B=reg_b[11:8], C0=C4_#2
    //   #4: A=reg_a[15:12], B=reg_b[15:12], C0=C4_#3
    // ============================================================
    wire c4_0, c4_1, c4_2;

    hc283 u_adder_0 (
        .A(reg_a_q[3:0]),
        .B(reg_b_q[3:0]),
        .C0(1'b0),
        .S(adder_lo[3:0]),
        .C4(c4_0)
    );

    hc283 u_adder_1 (
        .A(reg_a_q[7:4]),
        .B(reg_b_q[7:4]),
        .C0(c4_0),
        .S(adder_lo[7:4]),
        .C4(c4_1)
    );

    hc283 u_adder_2 (
        .A(reg_a_q[11:8]),
        .B(reg_b_q[11:8]),
        .C0(c4_1),
        .S(adder_hi[3:0]),
        .C4(c4_2)
    );

    hc283 u_adder_3 (
        .A(reg_a_q[15:12]),
        .B(reg_b_q[15:12]),
        .C0(c4_2),
        .S(adder_hi[7:4]),
        .C4()
    );

    assign adder_s = {adder_hi, adder_lo};

    // ============================================================
    // wavetable ROM (1 × 39SF040, 8-bit)
    //   地址布局 (与 gen_wavetable.py 一致):
    //     A[6:0]   = reg_a[15:9]   (相位高 7 位, 128 点波形)
    //     A[10:7]  = reg_c[3:0]    (音量, 16 级)
    //     A[12:11] = 2'b00         (默认 sine 波, 4 种波形预留)
    //   输出: 8-bit 波形数据 (含音量预乘)
    // ============================================================
    hc39sf040 #(.INIT_FILE("rom/wt3_wavetable.hex")) u_wave (
        .A0(reg_a_q[9]),   .A1(reg_a_q[10]), .A2(reg_a_q[11]),
        .A3(reg_a_q[12]),  .A4(reg_a_q[13]), .A5(reg_a_q[14]),
        .A6(reg_a_q[15]),
        .A7(reg_c_q[0]),   .A8(reg_c_q[1]),  .A9(reg_c_q[2]),
        .A10(reg_c_q[3]),
        .A11(1'b0), .A12(1'b0),
        .A13(1'b0), .A14(1'b0), .A15(1'b0),
        .A16(1'b0), .A17(1'b0), .A18(1'b0),
        .DQ(wave_do),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // ============================================================
    // 273: 8-bit DAC 输出锁存
    //   CP = 154 Y12 反相 (step=12 时上升沿)
    // ============================================================
    hc273 #(.WIDTH(8), .DELAY_RISE(15), .DELAY_FALL(15)) u_dac (
        .MR_n(SPFM_RST_n),
        .CP(latch_dac),
        .D(wave_do),
        .Q(dac_out)
    );

endmodule
