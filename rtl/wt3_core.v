// wt3_core.v — 161 + 单片 ROM + 157×5 + 62256 + 377×3 + 283
//
// 芯片清单 (14 IC):
//   SPFM 总线  (3): 373 (透明锁存) + 174 (同步器) + 377 (SPFM 地址寄存器)
//   数据锁存  (2): 377×2 (reg_a + reg_b)
//   step 计数  (1): 161 (级联, 5-bit, 32步)
//   微码 ROM   (1): 39SF040 (8-bit 控制字)
//   地址 mux   (5): 157 ×5
//                   #1 RAM 地址低 4 位 (reg_addr vs mc_ram_addr)
//                   #2 RAM 地址高 4 位 + WE 选择
//                   #3 DI 低 4 位 (reg_data vs adder_s)
//                   #4 DI 高 4 位 (reg_data vs 0)
//                   #5 OE_n 选择 (mc_oe vs 1)
//   参数 RAM   (1): 62256 (32K×8)
//   加法器     (1): 283 (4-bit 全加器)
//
// 微码 ROM 控制字 (8-bit):
//   bit 7: ram_oe_n   (0=read RAM)
//   bit 6: latch_a_n  (0=latch to reg_a, 低有效)
//   bit 5: latch_b_n  (0=latch to reg_b, 低有效)
//   bit 4: mc_we_n    (0=write adder result back to RAM)
//   bit 3-0: ram_addr[3:0]
//
// 数据通路 (单通道 4-bit 相位累加):
//   step 0: OE=0, addr=0x00 (read phase_acc, RAM 输出稳定)
//   step 1: latch_a_n=0, OE=0, addr=0x00 (377_a 锁存 RAM[0])
//   step 2: OE=0, addr=0x01 (read phase_step)
//   step 3: latch_b_n=0, OE=0, addr=0x01 (377_b 锁存 RAM[1])
//   step 4: mc_we_n=0, addr=0x00 (写回 283 结果到 RAM[0])
//   step 5-31: NOP
//   32 步循环 = 1 次累加, 96kHz

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

    output wire [7:0]  reg_a_q,
    output wire [7:0]  reg_b_q,
    output wire [3:0]  adder_s
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
    wire       ram_oe_n_mc;
    wire       latch_a_n;
    wire       latch_b_n;
    wire       mc_we_n;
    wire [3:0] mc_ram_addr;

    wire [7:0] ram_addr;
    wire [7:0] ram_do;
    wire       ram_oe_n;
    wire       ram_we_n;
    wire [7:0] ram_di;

    // ============================================================
    // Microcode decode
    // ============================================================
    assign ram_oe_n_mc = ucode[7];
    assign latch_a_n   = ucode[6];
    assign latch_b_n   = ucode[5];
    assign mc_we_n     = ucode[4];
    assign mc_ram_addr = ucode[3:0];

    // ============================================================
    // 157 #1: RAM 地址 mux 低 4 位
    //   Select=0 (SPFM) → reg_addr[3:0]
    //   Select=1 (微码) → mc_ram_addr[3:0]
    // ============================================================
    wire mux1_y0, mux1_y1, mux1_y2, mux1_y3;

    hc157 u_addr_lo (
        .Select(SPFM_CS_n),
        .A1(reg_addr[0]),     .B1(mc_ram_addr[0]),
        .A2(reg_addr[1]),     .B2(mc_ram_addr[1]),
        .A3(reg_addr[2]),     .B3(mc_ram_addr[2]),
        .A4(reg_addr[3]),     .B4(mc_ram_addr[3]),
        .Enable_n(1'b0),
        .Y1(mux1_y0), .Y2(mux1_y1),
        .Y3(mux1_y2), .Y4(mux1_y3)
    );

    assign ram_addr[0] = mux1_y0;
    assign ram_addr[1] = mux1_y1;
    assign ram_addr[2] = mux1_y2;
    assign ram_addr[3] = mux1_y3;

    // ============================================================
    // 157 #2: RAM 地址高 4 位 + WE 选择
    //   Y1=ram_addr[4]: Select=0→reg_addr[4], Select=1→0
    //   Y2=ram_addr[5]: Select=0→reg_addr[5], Select=1→0
    //   Y3=ram_addr[6]: Select=0→reg_addr[6], Select=1→0
    //   Y4=ram_addr[7]: Select=0→reg_addr[7], Select=1→0
    //   WE 单独: Select=0→data_wr_pulse_n, Select=1→mc_we_n (复用为 #5)
    // ============================================================
    // 实际上 WE 之前已经用了独立 157. 现在合并:
    //   #2 专做高 4 位地址
    //   WE 单独占一片 #5? 不, 一片 157 4 路, WE 只用 1 路, 浪费 3 路.
    //   重新分配:
    //     #2: 高 4 位地址 (4 路)
    //     #3: DI 低 4 位 (4 路)
    //     #4: DI 高 4 位 + OE_n (4 路, 用 3 路空 1 路给 OE? 不, 4 路 DI 用满)
    //   总共需要:
    //     - 地址低 4 位: #1
    //     - 地址高 4 位: #2
    //     - DI 低 4 位: #3
    //     - DI 高 4 位: #4
    //     - WE 1 路 + OE 1 路 = #5 (用 2 路, 空余 2 路)
    // ============================================================
    hc157 u_addr_hi (
        .Select(SPFM_CS_n),
        .A1(reg_addr[4]),     .B1(1'b0),
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
    //   Select=1 (微码) → adder_s[3:0]
    // ============================================================
    wire [3:0] di_lo;
    hc157 u_di_lo (
        .Select(SPFM_CS_n),
        .A1(reg_data[0]),     .B1(adder_s[0]),
        .A2(reg_data[1]),     .B2(adder_s[1]),
        .A3(reg_data[2]),     .B3(adder_s[2]),
        .A4(reg_data[3]),     .B4(adder_s[3]),
        .Enable_n(1'b0),
        .Y1(di_lo[0]), .Y2(di_lo[1]),
        .Y3(di_lo[2]), .Y4(di_lo[3])
    );

    // ============================================================
    // 157 #4: RAM DI 高 4 位
    //   Select=0 (SPFM) → reg_data[7:4]
    //   Select=1 (微码) → 0 (adder 只有 4 位, 高位补 0)
    // ============================================================
    wire [3:0] di_hi;
    hc157 u_di_hi (
        .Select(SPFM_CS_n),
        .A1(reg_data[4]),     .B1(1'b0),
        .A2(reg_data[5]),     .B2(1'b0),
        .A3(reg_data[6]),     .B3(1'b0),
        .A4(reg_data[7]),     .B4(1'b0),
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
    // ============================================================
    wire [18:0] mc_addr = {14'b0, step};

    hc39sf040 #(.INIT_FILE("rom/wt3_microcode.hex")) u_mc (
        .A0(mc_addr[0]),  .A1(mc_addr[1]),  .A2(mc_addr[2]),
        .A3(mc_addr[3]),  .A4(mc_addr[4]),  .A5(1'b0),
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
    // 377 reg_a: 锁存 phase_acc
    // ============================================================
    hc377 u_reg_a (
        .Enable_bar(latch_a_n),
        .D(ram_do),
        .Clk(STEP_CLK),
        .Q(reg_a_q)
    );

    // ============================================================
    // 377 reg_b: 锁存 phase_step
    // ============================================================
    hc377 u_reg_b (
        .Enable_bar(latch_b_n),
        .D(ram_do),
        .Clk(STEP_CLK),
        .Q(reg_b_q)
    );

    // ============================================================
    // 283: 4-bit 加法器
    //   A = reg_a_q[3:0] (phase_acc)
    //   B = reg_b_q[3:0] (phase_step)
    //   C0 = 0
    // ============================================================
    wire adder_c4;

    hc283 u_adder (
        .A(reg_a_q[3:0]),
        .B(reg_b_q[3:0]),
        .C0(1'b0),
        .S(adder_s),
        .C4(adder_c4)
    );

    wire _unused = &{adder_c4, 1'b0};

endmodule
