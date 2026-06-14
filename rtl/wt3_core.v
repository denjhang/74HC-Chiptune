// wt3_core.v — 161 step + 单片微码 ROM + 157 mux + 62256 + 377 锁存
//
// 芯片清单 (8 IC):
//   SPFM 总线  (3): 373 (透明锁存) + 174 (同步器) + 377 (地址寄存器)
//   数据锁存  (1): 377 (RAM 输出锁存)
//   step 计数  (1): 161 (级联, 5-bit, 32步)
//   微码 ROM   (1): 39SF040 (8-bit 控制字)
//   地址 mux   (1): 157 (RAM 地址选择: 微码 vs SPFM)
//   参数 RAM   (1): 62256 (32K×8)
//
// 微码 ROM 控制字 (8-bit):
//   bit 7: ram_oe_n   (0=read RAM)
//   bit 6: latch_n    (0=latch RAM output to 377, 低有效)
//   bit 5-0: ram_addr[5:0] (直接接 62256 A[5:0])

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

    output wire [7:0]  reg_out
);

    // ============================================================
    // Wire declarations
    // ============================================================
    wire [7:0] reg_addr;
    wire [7:0] reg_data;
    wire       addr_wr_pulse_n;
    wire       data_wr_pulse_n;

    wire [4:0] step;

    wire [7:0] ucode;
    wire       ram_oe_n_mc;   // 微码侧 RAM OE (低有效)
    wire       latch_n;       // 377 latch enable (低有效)
    wire [5:0] mc_ram_addr;  // 微码侧 RAM 地址

    wire [7:0] ram_addr;
    wire [7:0] ram_do;

    // ============================================================
    // Microcode decode
    // ============================================================
    assign ram_oe_n_mc = ucode[7];
    assign latch_n     = ucode[6];
    assign mc_ram_addr = ucode[5:0];

    // RAM OE: SPFM 操作时不读
    wire ram_oe_n = SPFM_CS_n ? ram_oe_n_mc : 1'b1;
    wire ram_we_n = data_wr_pulse_n;

    // ============================================================
    // 157: RAM 地址 mux (低 4 位)
    //   CS_n=0 → Select=0 → Y=A → A 接 reg_addr
    //   CS_n=1 → Select=1 → Y=B → B 接 mc_ram_addr
    // ============================================================
    wire mux_y0, mux_y1, mux_y2, mux_y3;

    hc157 u_addr_mux (
        .Select(SPFM_CS_n),
        .A1(reg_addr[0]),     .B1(mc_ram_addr[0]),
        .A2(reg_addr[1]),     .B2(mc_ram_addr[1]),
        .A3(reg_addr[2]),     .B3(mc_ram_addr[2]),
        .A4(reg_addr[3]),     .B4(mc_ram_addr[3]),
        .Enable_n(1'b0),
        .Y1(mux_y0), .Y2(mux_y1),
        .Y3(mux_y2), .Y4(mux_y3)
    );

    assign ram_addr[0] = mux_y0;
    assign ram_addr[1] = mux_y1;
    assign ram_addr[2] = mux_y2;
    assign ram_addr[3] = mux_y3;
    assign ram_addr[5:4] = SPFM_CS_n ? mc_ram_addr[5:4] : reg_addr[5:4];
    assign ram_addr[7:6] = SPFM_CS_n ? 2'b00 : reg_addr[7:6];

    // ============================================================
    // SPFM 总线 (3 IC: 373, 174, 377)
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
    // 161: 5-bit step counter (32 steps)
    // ============================================================
    wire tc_lo;
    wire [3:0] step_lo;
    wire step_hi;

    hc161 u_step_lo (
        .MR(1'b1), .CP(STEP_CLK),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(step_lo[0]), .Q1(step_lo[1]),
        .Q2(step_lo[2]), .Q3(step_lo[3]),
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
    // 微码 ROM (1 × 39SF040, 8-bit)
    //   A[4:0] = step, A[18:5] = 0
    // ============================================================
    wire [18:0] mc_addr = {14'b0, step};

    hc39sf040 #(.INIT_FILE("rom/wt3_microcode.hex")) u_mc (
        .A0(mc_addr[0]),  .A1(mc_addr[1]),  .A2(mc_addr[2]),
        .A3(mc_addr[3]),  .A4(mc_addr[4]),  .A5(1'b0),
        .A6(1'b0), .A7(1'b0),  .A8(1'b0),  .A9(1'b0),
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
        .DI(reg_data),
        .DO(ram_do),
        .CE_n(1'b0),
        .OE_n(ram_oe_n),
        .WE_n(ram_we_n)
    );

    // ============================================================
    // 377: RAM 输出锁存
    //   Enable_bar = latch_n (直连, 低有效)
    // ============================================================
    hc377 u_out_latch (
        .Enable_bar(latch_n),
        .D(ram_do),
        .Clk(STEP_CLK),
        .Q(reg_out)
    );

endmodule
