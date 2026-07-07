// psg3_top.v — PSG3 v0.4 顶层 (YM2413 总线 + PSG2 方波 + 噪音两通道)
//
// 把 PSG2 v0.3 的方波 (CH0) + 噪音 (CH1) 挂到 PSG3 总线上.
// 总线层: HC374 地址锁存 (独热码) + HC08 选通 + 8×HC374 寄存器 (本版用 reg0/1/6)
// 通道层: 复用 PSG2 v0.3 逻辑, 但 period/ctrl 从总线寄存器 Q 端取 (不再自带锁存)
//
// 寄存器映射 (独热码地址):
//   reg0 (0x01): CH0 period   — 方波频率 (8 bit)
//   reg1 (0x02): CH0 控制     — 音量(4)/占空比(2)/mode(1)/ref(1)
//   reg6 (0x40): 噪音控制     — 音量(4)/频率挡(2)/绑定(1)
//   (reg2-5/7 预留, 地址位悬空)
//
// FT232H 接线 (12 根, 物理不动):
//   C0-C7 = D0-D7 复用总线, D4=A0, D5=/WR, D6=/RST, D7=/CS

`timescale 1ns/1ps

module psg3_top (
    input        clk,         // 64kHz 全局晶振
    input        rst_n,       // 复位 (低有效)
    input  [7:0] bus_data,    // C0-C7 复用总线
    input        A0,          // 0=写地址, 1=写数据
    input        WR_n,        // 写脉冲 (低有效, 上升沿锁存)
    input        CS_n,        // 片选 (低有效, 事务边界)
    output [7:0] sq_audio,    // 方波通道 TLC7524 输出
    output [7:0] nz_audio,    // 噪音通道 TLC7524 输出
    output       tc_out       // 方波 TC (观测/噪音绑定用)
);

    // ============================================================
    // 总线层: 地址锁存 + 选通逻辑 + 寄存器 (仿 YM2413)
    // ============================================================

    // ---- NOT 逻辑 (HC04) ----
    wire cs_active = ~CS_n;     // 事务期间=1
    wire a0_n      = ~A0;

    // ---- 锁存触发 (HC08 组合) ----
    wire addr_cp     = cs_active & a0_n & WR_n;   // 写地址: /CS=0 + A0=0 + /WR↑
    wire data_strobe = cs_active & A0    & WR_n;   // 写数据: /CS=0 + A0=1 + /WR↑

    // ---- 地址锁存 (HC374 边沿, 独热码) ----
    wire [7:0] addr_out;
    hc374 u_addr (
        .OE_n(1'b0), .CP(addr_cp),
        .D(bus_data), .Q(addr_out)
    );

    // ---- 8 个数据寄存器 (HC374), 每个由独热码地址位选通 ----
    // CP[n] = addr_out[n] AND data_strobe
    wire [7:0] reg_cp;
    assign reg_cp[0] = addr_out[0] & data_strobe;
    assign reg_cp[1] = addr_out[1] & data_strobe;
    assign reg_cp[2] = addr_out[2] & data_strobe;
    assign reg_cp[3] = addr_out[3] & data_strobe;
    assign reg_cp[4] = addr_out[4] & data_strobe;
    assign reg_cp[5] = addr_out[5] & data_strobe;
    assign reg_cp[6] = addr_out[6] & data_strobe;
    assign reg_cp[7] = addr_out[7] & data_strobe;

    wire [7:0] reg0_q, reg1_q, reg2_q, reg3_q, reg4_q, reg5_q, reg6_q, reg7_q;

    hc374 u_reg0 (.OE_n(1'b0), .CP(reg_cp[0]), .D(bus_data), .Q(reg0_q)); // CH0 period
    hc374 u_reg1 (.OE_n(1'b0), .CP(reg_cp[1]), .D(bus_data), .Q(reg1_q)); // CH0 控制
    hc374 u_reg2 (.OE_n(1'b0), .CP(reg_cp[2]), .D(bus_data), .Q(reg2_q)); // 预留
    hc374 u_reg3 (.OE_n(1'b0), .CP(reg_cp[3]), .D(bus_data), .Q(reg3_q)); // 预留
    hc374 u_reg4 (.OE_n(1'b0), .CP(reg_cp[4]), .D(bus_data), .Q(reg4_q)); // 预留
    hc374 u_reg5 (.OE_n(1'b0), .CP(reg_cp[5]), .D(bus_data), .Q(reg5_q)); // 预留
    hc374 u_reg6 (.OE_n(1'b0), .CP(reg_cp[6]), .D(bus_data), .Q(reg6_q)); // 噪音控制
    hc374 u_reg7 (.OE_n(1'b0), .CP(reg_cp[7]), .D(bus_data), .Q(reg7_q)); // 预留

    // ============================================================
    // 方波通道 CH0 (复用 PSG2 v0.3 逻辑, period/ctrl 从总线 reg0/reg1 取)
    // ============================================================
    wire [7:0] period_q = reg0_q;            // CH0 period
    wire [3:0] sq_vol      = reg1_q[3:0];    // 音量 (bit0-3)
    wire [1:0] duty_sel    = reg1_q[5:4];    // 占空比挡 (bit4-5)
    wire       mode_sel    = reg1_q[6];      // mode (bit6: 0=方波, 1=白噪)
    // ref_sel (bit7) 控制 HC4053 开关 Z, RTL 行为级不使用 (硬件物理音色仿真复现不了)

    // ---- 计数器 (HC161 x2) ----
    wire tc_lo, tc_hi;
    wire [3:0] q_lo, q_hi;
    wire pe_n;

    hc161 u_cnt_lo (
        .MR(rst_n), .CP(clk),
        .D0(period_q[0]),.D1(period_q[1]),.D2(period_q[2]),.D3(period_q[3]),
        .Q0(q_lo[0]),.Q1(q_lo[1]),.Q2(q_lo[2]),.Q3(q_lo[3]),
        .CEP(1'b1),.CET(1'b1),.PE(pe_n),.TC(tc_lo)
    );
    hc161 u_cnt_hi (
        .MR(rst_n), .CP(clk),
        .D0(period_q[4]),.D1(period_q[5]),.D2(period_q[6]),.D3(period_q[7]),
        .Q0(q_hi[0]),.Q1(q_hi[1]),.Q2(q_hi[2]),.Q3(q_hi[3]),
        .CEP(tc_lo),.CET(tc_lo),.PE(pe_n),.TC(tc_hi)
    );
    assign tc_out = tc_hi;

    // ---- PE 反相 (HC00 第1路) ----
    hc00 u_nand (
        .A1(tc_hi),.B1(tc_hi),.Y1(pe_n),
        .A2(1'b0),.B2(1'b0),.Y2(),
        .A3(1'b0),.B3(1'b0),.Y3(),
        .A4(1'b0),.B4(1'b0),.Y4()
    );

    // ---- 方波/白噪二选一 (HC4053 开关 X, RTL 用 mux 等效) ----
    wire reload_src = mode_sel ? pe_n : tc_hi;

    // ---- toggle 链 (FF1 sync + FF2 toggle=Q1 + FF3÷2=Q2 + FF4÷2=Q3) ----
    reg reload_pulse = 1'b0;
    reg q1 = 1'b0, q2 = 1'b0, q3 = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) reload_pulse <= 1'b0;
        else        reload_pulse <= reload_src;
    end
    always @(posedge reload_pulse or negedge rst_n) begin
        if (!rst_n) q1 <= 1'b0; else q1 <= ~q1;
    end
    always @(posedge q1 or negedge rst_n) begin
        if (!rst_n) q2 <= 1'b0; else q2 <= ~q2;
    end
    always @(posedge q2 or negedge rst_n) begin
        if (!rst_n) q3 <= 1'b0; else q3 <= ~q3;
    end

    // ---- 占空比组合 + 选通 (HC08 AND + HC153 4选1) ----
    wire duty_50   = q1;
    wire duty_25   = q1 & q2;
    wire duty_125  = q1 & q2 & q3;
    wire duty_25f4 = q2 & q3;

    reg wave_sel;
    always @(*) begin
        case (duty_sel)
            2'b00: wave_sel = duty_50;
            2'b01: wave_sel = duty_25;
            2'b10: wave_sel = duty_125;
            2'b11: wave_sel = duty_25f4;
        endcase
    end

    // ---- TLC7524 衰减器 (方波) ----
    assign sq_audio = wave_sel ? (sq_vol << 4) : 8'd0;

    // ============================================================
    // 噪音通道 CH1 (复用 PSG2 v0.3 rev.a 逻辑, ctrl 从总线 reg6 取)
    // ============================================================
    wire [3:0] nz_vol     = reg6_q[3:0];   // 音量 (bit0-3)
    wire [1:0] freq_sel   = reg6_q[5:4];   // 频率挡 (bit4-5)
    wire       bind_sw    = reg6_q[6];     // 绑定开关 (bit6)

    // ---- 独立分频器 (HC161 自由计数, ÷2/÷4/÷8/÷16) ----
    wire [3:0] div_q;
    wire       div_tc;
    hc161 u_div161 (
        .MR(1'b1), .CP(clk),
        .D0(1'b0),.D1(1'b0),.D2(1'b0),.D3(1'b0),
        .Q0(div_q[0]),.Q1(div_q[1]),.Q2(div_q[2]),.Q3(div_q[3]),
        .CEP(1'b1),.CET(1'b1),.PE(1'b1),.TC(div_tc)
    );

    // ---- 频率选通 (HC153 上半部 4 选 1) ----
    wire ind_clk;
    hc153 u_mux (
        .A(freq_sel[0]), .B(freq_sel[1]),
        ._1G_n(1'b0),
        ._1C0(div_q[0]), ._1C1(div_q[1]),
        ._1C2(div_q[2]), ._1C3(div_q[3]),
        ._1Y(ind_clk),
        ._2G_n(1'b1),
        ._2C0(1'b0), ._2C1(1'b0), ._2C2(1'b0), ._2C3(1'b0),
        ._2Y()
    );

    // ---- 绑定 2 选 1 (硬件用 HC00, RTL 用 mux) ----
    wire noise_clk = bind_sw ? tc_hi : ind_clk;

    // ---- LFSR 主体 (HC374 八 D 触发器, max-length 周期 255) ----
    reg [7:0] lfsr_q = 8'h00;
    reg [7:0] lfsr_d;
    reg [4:0] startup_cnt = 5'd0;
    wire      startup_active = (startup_cnt < 5'd16);

    wire xor_a = lfsr_q[7] ^ lfsr_q[5];
    wire xor_b = lfsr_q[4] ^ lfsr_q[3];
    wire feedback = xor_a ^ xor_b;

    assign lfsr_d[0] = startup_active ? 1'b1 : feedback;
    assign lfsr_d[1] = lfsr_q[0];
    assign lfsr_d[2] = lfsr_q[1];
    assign lfsr_d[3] = lfsr_q[2];
    assign lfsr_d[4] = lfsr_q[3];
    assign lfsr_d[5] = lfsr_q[4];
    assign lfsr_d[6] = lfsr_q[5];
    assign lfsr_d[7] = lfsr_q[6];

    always @(posedge noise_clk) begin
        lfsr_q <= lfsr_d;
        if (startup_active)
            startup_cnt <= startup_cnt + 5'd1;
    end

    // ---- TLC7524 衰减器 (噪音, REF=Q7) ----
    assign nz_audio = lfsr_q[7] ? (nz_vol << 4) : 8'd0;

endmodule
