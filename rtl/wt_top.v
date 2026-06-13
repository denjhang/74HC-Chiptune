// wt_top.v — 74HC-Chiptune 顶层模块 (9 IC)
//
// 芯片清单:
//   SPFM 总线 (3 IC): 373, 174, 377
//   合成器核心 (6 IC): 161×2, 283, 174, 273, 7134, 62256, 39SF040×2
//     其中 39SF040: 1片指令ROM(8-bit) + 1片波表ROM
//
// 时钟: 3.072MHz → 32 步循环 → 96kHz 采样率 (与 WSG 一致)
// 数据通路:
//   STEP_CLK → hc161×2(step[4:0]) → 指令ROM(8-bit控制字) → 7134+62256+283+174+波表ROM+273
//   voice_sel = step[4:3], param_addr = step[2:0] (硬件推导, 不存ROM)
//   SPFM总线 → 7134 Left (CPU写参数)
//
// 32 步分配: 3通道 × 8步 = 24 + 8 NOP
//   每通道: 5累加(nib0-4) + vol读 + wave读 + 查表 = 8步

`timescale 1ns/1ps

module wt_top (
    // STEP_CLK: 3.072MHz 晶振直驱
    input  wire        STEP_CLK,

    // SPFM 总线 (来自主机)
    input  wire        SPFM_CLK,
    input  wire        SPFM_RST_n,
    input  wire [7:0]  SPFM_D,
    input  wire        SPFM_A0,
    input  wire        SPFM_CS_n,
    input  wire        SPFM_WR_n,
    input  wire        SPFM_RD_n,

    // DAC 输出 (混音后 8-bit)
    output wire [7:0]  dac_out
);

    // ============================================================
    // SPFM 总线接口 (3 IC: 373 + 174 + 377)
    // ============================================================
    wire [7:0]  reg_addr;
    wire [7:0]  reg_data;
    wire        addr_wr;
    wire        data_wr;

    wt_spfm_bus u_spfm (
        .CLK(SPFM_CLK),
        .RST_n(SPFM_RST_n),
        .D(SPFM_D),
        .A0(SPFM_A0),
        .CS_n(SPFM_CS_n),
        .WR_n(SPFM_WR_n),
        .RD_n(SPFM_RD_n),
        .reg_addr(reg_addr),
        .reg_data(reg_data),
        .addr_wr(addr_wr),
        .data_wr(data_wr)
    );

    // ============================================================
    // hc161 × 2: 微步计数器 (step[4:0], 0-31 循环)
    // 低4位: step[3:0], 高位: step[4]
    // 级联: U1.TC → U2.CET
    // ============================================================
    wire [3:0] step_lo;
    wire       tc_lo;

    hc161 u_step_lo (
        .MR(1'b1),
        .CP(STEP_CLK),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(step_lo[0]), .Q1(step_lo[1]), .Q2(step_lo[2]), .Q3(step_lo[3]),
        .CEP(1'b1), .CET(1'b1), .PE(1'b1),
        .TC(tc_lo)
    );

    wire step_hi_q0;
    hc161 u_step_hi (
        .MR(1'b1),
        .CP(STEP_CLK),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(step_hi_q0), .Q1(), .Q2(), .Q3(),
        .CEP(tc_lo), .CET(1'b1), .PE(1'b1),
        .TC()
    );

    wire [4:0] step = {step_hi_q0, step_lo};

    // ============================================================
    // 指令 ROM (39SF040 #1, 8-bit 控制字)
    // 地址 = step (0-31)
    // voice_sel = step[4:3], param_addr = step[2:0] (硬件推导)
    // ============================================================
    wire [18:0] inst_addr = {14'b0, step};
    wire [7:0]  inst_dq;

    wire        c_adder_clk   = inst_dq[7];
    wire        c_out_latch   = inst_dq[6];
    wire        c_param_oe_n  = inst_dq[5];
    wire        c_ram_oe_n    = inst_dq[4];
    wire        c_rom_oe_n    = inst_dq[3];
    wire        c_adder_clr_n = inst_dq[2];
    wire [2:0]  c_param_addr  = step[2:0];  // 硬件推导: 0-4=freq, 5=wave, 6=vol
    wire [1:0]  c_voice       = step[4:3];  // 硬件推导: 00=v0, 01=v1, 10=v2

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
    // 7134: 双端口参数 RAM
    // Left: SPFM 总线写入
    // Right: 合成器读取 (控制字 c_param_addr 驱动地址)
    // ============================================================
    wire        ce_L_n = ~data_wr;
    wire        oe_L_n = 1'b1;
    wire        rw_L   = 1'b0;    // Left 端口只写: RW 固定低
    wire [7:0]  di_L    = reg_data;

    // Right 端口地址 = voice×8 + param_addr
    wire [11:0] addr_R = {7'b0, c_voice, 3'b0} + {9'b0, c_param_addr};

    wire        ce_R_n = c_param_oe_n;
    wire        oe_R_n = c_param_oe_n;
    wire        rw_R   = 1'b1;    // Right 端口只读: RW 固定高
    wire [7:0]  do_r;

    hc7134 u_param (
        .A0L(reg_addr[0]),  .A1L(reg_addr[1]),  .A2L(reg_addr[2]),
        .A3L(reg_addr[3]),  .A4L(reg_addr[4]),  .A5L(reg_addr[5]),
        .A6L(reg_addr[6]),  .A7L(reg_addr[7]),  .A8L(1'b0),
        .A9L(1'b0),  .A10L(1'b0), .A11L(1'b0),
        .DI_L(di_L), .DO_L(),  // Left: 只写, DO_L 悬空
        .CE_L_n(ce_L_n), .OE_L_n(oe_L_n), .RW_L(rw_L),
        .A0R(addr_R[0]),  .A1R(addr_R[1]),  .A2R(addr_R[2]),
        .A3R(addr_R[3]),  .A4R(addr_R[4]),  .A5R(addr_R[5]),
        .A6R(addr_R[6]),  .A7R(addr_R[7]),  .A8R(addr_R[8]),
        .A9R(addr_R[9]),  .A10R(addr_R[10]), .A11R(addr_R[11]),
        .DI_R(8'h00), .DO_R(do_r),  // Right: 只读, DI_R 接地
        .CE_R_n(ce_R_n), .OE_R_n(oe_R_n), .RW_R(rw_R)
    );

    // ============================================================
    // Phase 存储 (原 62256, 仿真用 reg 实现)
    // phase_mem[voice][nibble] — 4 voice × 5 nibble
    // ============================================================
    reg  [5:0] accum_q = 6'd0;
    reg [3:0] phase_mem [0:14];  // [voice*5 + nib], voice 0-2, nib 0-4
    integer _i; initial for (_i = 0; _i < 15; _i = _i + 1) phase_mem[_i] = 4'b0;
    wire [4:0] phase_idx = {c_voice, c_param_addr};
    wire [3:0] ram_dout = (c_voice < 3) ? phase_mem[phase_idx] : 4'b0;

    // ============================================================
    // hc283 + 累加器寄存器 (原 174, 改为 reg 实现)
    // CLK=STEP_CLK, 只在 c_adder_clk=1 时锁存加法结果
    // ============================================================
    wire [3:0] add_a = ram_dout[3:0];
    wire [3:0] add_b = (c_param_oe_n == 1'b0) ? do_r[3:0] : 4'b0;
    wire add_c0 = c_adder_clr_n ? accum_q[4] : 1'b0;
    wire [3:0] add_sum;
    wire       add_c4;

    hc283 u_adder (
        .A(add_a), .B(add_b), .C0(add_c0),
        .S(add_sum), .C4(add_c4)
    );


    // ============================================================
    // vol/wave 锁存 + phase 寄存器 + 混音 (reg 声明在前)
    // ============================================================
    reg [19:0] phase_v0, phase_v1, phase_v2;
    reg [7:0]  mix_out = 8'd0;
    reg [3:0]  cur_vol_r = 4'd0;
    reg [2:0]  cur_wave_r = 3'd0;

    // ============================================================
    // 波表 ROM 地址 + 输出
    // addr = wave[2:0] × 2048 + vol[3:0] × 128 + phase[19:12]
    // ============================================================
    wire [19:0] cur_phase = (c_voice == 2'd0) ? phase_v0
                           : (c_voice == 2'd1) ? phase_v1
                           : phase_v2;
    wire [18:0] rom_addr_w = {cur_wave_r, cur_vol_r, cur_phase[19:12]};
    wire [7:0]  rom_dq;

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

    // posedge STEP_CLK:
    //   accum 步: 锁存加法结果到 phase
    //   vol_read 步: 锁存 7134 vol
    //   wave_read 步: 锁存 7134 wave
    //   lookup 步: 混音加法
    always @(posedge STEP_CLK) begin
        if (c_adder_clk) begin
            accum_q <= {accum_q[3], add_c4, add_sum};
            // 写回 phase_mem 和 phase_v*
            phase_mem[{c_voice, c_param_addr}] <= add_sum;
            case (c_voice)
                2'd0: phase_v0[c_param_addr*4 +: 4] <= add_sum;
                2'd1: phase_v1[c_param_addr*4 +: 4] <= add_sum;
                2'd2: phase_v2[c_param_addr*4 +: 4] <= add_sum;
            endcase
        end
        if (c_param_oe_n == 1'b0 && c_adder_clk == 1'b0) begin
            if (c_param_addr == 3'd6)
                cur_vol_r <= do_r[3:0];
            else if (c_param_addr == 3'd5)
                cur_wave_r <= do_r[2:0];
        end
        if (c_out_latch) begin
            if (c_voice == 2'd0)
                mix_out <= rom_dq;
            else
                mix_out <= mix_out + rom_dq;
        end
    end

    // ============================================================
    // DAC 输出: voice2 查表步锁存 mix_out
    // 用 reg 直接锁存 (与 mix_out 在同一个 always 块内, 避免 delta cycle 竞争)
    // ============================================================
    reg [7:0] dac_out_r = 8'd0;

    always @(posedge STEP_CLK) begin
        if (c_out_latch && c_voice == 2'd2)
            dac_out_r <= mix_out;
    end

    assign dac_out = dac_out_r;

endmodule
