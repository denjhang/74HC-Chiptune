// psg3_top.v — PSG3 v0.5 顶层 (YM2413 总线 + 方波 + 波形 + 噪音 三通道)
//
// v0.5 架构: 晶振 4MHz, 三通道并存:
//   - 方波通道 CH0 (v0.4 不变): reg0/1, clk=sq_clk (预分频 64kHz)
//   - 波形通道 CH2 (v0.5 新):  reg3/4/5, clk=4MHz 直连
//       CD4029 4-bit 计数器, wave_sel 切 方波/三角/锯齿/反锯齿
//   - 噪音通道 CH1 (v0.4 不变): reg6, clk=sq_clk
//
// 周期分两类 (波形通道, 核心: wave_sel[0]=fold 控制有无 CD4027 折返):
//   锯齿族 (锯齿/方波/反锯齿, fold=0): 单向回绕 = 16步/周期
//       freq = 4MHz / (16 × (4096 - period12))
//   三角 (fold=1): CD4027 折返 0→15→0 = 30步/周期
//       freq = 4MHz / (30 × (4096 - period12))
//   → 两套 period 查找表: host/uni_period_table.h (saw/tri)
//
// 寄存器映射 (独热码地址):
//   reg0 (0x01): 方波 period (8 bit)              ← v0.4 不变
//   reg1 (0x02): 方波控制 vol/duty/mode/ref       ← v0.4 不变
//   reg2 (0x04): 噪音控制 vol/freq/bind
//   reg3 (0x08): 波形通道 period12[7:0]
//   reg4 (0x10): 波形通道 period12[11:8] | vol[3:0]
//   reg5 (0x20): 波形通道 duty[3:0](bit0-3) | mode_sel(bit4) | wave_sel[1:0](bit5-6) | 预留(bit7)
//                wave_sel[1] = dir  (0=加=锯齿/方波, 1=减=反锯齿)
//                wave_sel[0] = fold (0=单向16步=锯齿族, 1=折返30步=三角)
//                → wave_sel 编码: 00锯齿 01三角 10方波 11反锯齿
//                方波 = dir=0 + fold=0 + 强制走 HC85 比较 (mode_sel 无效)
//                duty4: 比较阈值/AND掩码 (音色调制参数)
//                mode_sel: 1=HC85比较(阈值调制) 0=HC08 AND(位掩码调制)
//   (reg6/7 预留)
//
// FT232H 接线 (12 根, 物理不动):
//   C0-C7 = D0-D7 复用总线, D4=A0, D5=/WR, D6=/RST, D7=/CS

`timescale 1ns/1ps

module psg3_top (
    input        clk,         // 4MHz 全局晶振
    input        rst_n,       // 复位 (低有效)
    input  [7:0] bus_data,    // C0-C7 复用总线
    input        A0,          // 0=写地址, 1=写数据
    input        WR_n,        // 写脉冲 (低有效, 上升沿锁存)
    input        CS_n,        // 片选 (低有效, 事务边界)
    output [7:0] sq_audio,    // 方波通道 TLC7524 输出 (v0.4 不变)
    output [7:0] uni_audio,   // 波形通道 TLC7524 输出 (v0.5 新)
    output [7:0] nz_audio,    // 噪音通道 TLC7524 输出
    output       sq_tc,       // 方波 TC (观测/噪音绑定用)
    output       uni_tc       // 波形通道 freq_tc (观测用)
);

    // ============================================================
    // 时钟: 4MHz → ÷63 预分频 → sq_clk (63492Hz, 噪音用)
    // 统一通道直接用 clk (4MHz 全速, 16步@4M 覆盖 B1~C8)
    // ============================================================
    wire sq_pre_tc_lo, sq_pre_tc_hi, sq_pre_pe_n;
    wire [3:0] sq_pre_lo_q, sq_pre_hi_q;
    wire sq_clk;
    hc161 u_sqpre_lo (
        .MR(rst_n), .CP(clk),
        .D0(1'b1),.D1(1'b0),.D2(1'b0),.D3(1'b0),   // reload[3:0]=0x1
        .Q0(sq_pre_lo_q[0]),.Q1(sq_pre_lo_q[1]),.Q2(sq_pre_lo_q[2]),.Q3(sq_pre_lo_q[3]),
        .CEP(1'b1),.CET(1'b1),.PE(sq_pre_pe_n),.TC(sq_pre_tc_lo)
    );
    hc161 u_sqpre_hi (
        .MR(rst_n), .CP(clk),
        .D0(1'b0),.D1(1'b0),.D2(1'b1),.D3(1'b1),   // reload[7:4]=0xC
        .Q0(sq_pre_hi_q[0]),.Q1(sq_pre_hi_q[1]),.Q2(sq_pre_hi_q[2]),.Q3(sq_pre_hi_q[3]),
        .CEP(sq_pre_tc_lo),.CET(sq_pre_tc_lo),.PE(sq_pre_pe_n),.TC(sq_pre_tc_hi)
    );
    hc00 u_sqpre_nand (
        .A1(sq_pre_tc_hi),.B1(sq_pre_tc_hi),.Y1(sq_pre_pe_n),
        .A2(1'b0),.B2(1'b0),.Y2(),
        .A3(1'b0),.B3(1'b0),.Y3(),
        .A4(1'b0),.B4(1'b0),.Y4()
    );
    assign sq_clk = sq_pre_tc_hi;   // ÷63 (63492Hz), 噪音时钟

    // ============================================================
    // 总线层: 地址锁存 + 选通逻辑 + 寄存器 (仿 YM2413)
    // ============================================================
    wire cs_active = ~CS_n;
    wire a0_n      = ~A0;
    wire addr_cp     = cs_active & a0_n & WR_n;
    wire data_strobe = cs_active & A0    & WR_n;

    wire [7:0] addr_out;
    hc374 u_addr (.OE_n(1'b0), .CP(addr_cp), .D(bus_data), .Q(addr_out));

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
    hc374 u_reg0 (.OE_n(1'b0), .CP(reg_cp[0]), .D(bus_data), .Q(reg0_q)); // 方波 period (8 bit)
    hc374 u_reg1 (.OE_n(1'b0), .CP(reg_cp[1]), .D(bus_data), .Q(reg1_q)); // 方波控制 vol/duty/mode
    hc374 u_reg2 (.OE_n(1'b0), .CP(reg_cp[2]), .D(bus_data), .Q(reg2_q)); // 噪音控制 vol/freq/bind
    hc374 u_reg3 (.OE_n(1'b0), .CP(reg_cp[3]), .D(bus_data), .Q(reg3_q)); // 波形 period[7:0]
    hc374 u_reg4 (.OE_n(1'b0), .CP(reg_cp[4]), .D(bus_data), .Q(reg4_q)); // 波形 period[11:8]|vol
    hc374 u_reg5 (.OE_n(1'b0), .CP(reg_cp[5]), .D(bus_data), .Q(reg5_q)); // 波形 duty|wave|mode
    hc374 u_reg6 (.OE_n(1'b0), .CP(reg_cp[6]), .D(bus_data), .Q(reg6_q)); // 预留
    hc374 u_reg7 (.OE_n(1'b0), .CP(reg_cp[7]), .D(bus_data), .Q(reg7_q)); // 预留

    // ============================================================
    // 方波通道 CH0 (v0.4 原样保留, clk=sq_clk 预分频 64kHz)
    // ============================================================
    wire [7:0] sq_period  = reg0_q;           // CH0 period (8 bit)
    wire [3:0] sq_vol     = reg1_q[3:0];      // 音量 (bit0-3)
    wire [1:0] sq_duty    = reg1_q[5:4];      // 占空比挡 (bit4-5)
    wire       sq_mode    = reg1_q[6];        // mode (bit6: 0=方波, 1=白噪)

    // 计数器 (HC161 x2, clk=sq_clk)
    wire sq_tc_lo, sq_tc_hi;
    wire [3:0] sq_q_lo, sq_q_hi;
    wire sq_pe_n;
    hc161 u_sqcnt_lo (.MR(rst_n), .CP(sq_clk),
        .D0(sq_period[0]),.D1(sq_period[1]),.D2(sq_period[2]),.D3(sq_period[3]),
        .Q0(sq_q_lo[0]),.Q1(sq_q_lo[1]),.Q2(sq_q_lo[2]),.Q3(sq_q_lo[3]),
        .CEP(1'b1),.CET(1'b1),.PE(sq_pe_n),.TC(sq_tc_lo));
    hc161 u_sqcnt_hi (.MR(rst_n), .CP(sq_clk),
        .D0(sq_period[4]),.D1(sq_period[5]),.D2(sq_period[6]),.D3(sq_period[7]),
        .Q0(sq_q_hi[0]),.Q1(sq_q_hi[1]),.Q2(sq_q_hi[2]),.Q3(sq_q_hi[3]),
        .CEP(sq_tc_lo),.CET(sq_tc_lo),.PE(sq_pe_n),.TC(sq_tc_hi));
    assign sq_tc = sq_tc_hi;

    // PE 反相 (借用预分频的 U39 HC00? 不, 方波单独要 PE 反相)
    // ⚠️ 方波通道 PE 反相需要独立 HC00 门 (sq_pe_n = ~sq_tc_hi)
    hc00 u_sqpe (
        .A1(sq_tc_hi),.B1(sq_tc_hi),.Y1(sq_pe_n),
        .A2(1'b0),.B2(1'b0),.Y2(), .A3(1'b0),.B3(1'b0),.Y3(), .A4(1'b0),.B4(1'b0),.Y4());

    // 方波/白噪二选一 (mode_sel: 0=方波 tc_hi, 1=白噪 pe_n)
    wire sq_reload_src = sq_mode ? sq_pe_n : sq_tc_hi;

    // toggle 链 (FF1 sync + FF2 toggle + FF3÷2 + FF4÷2)
    reg sq_reload_pulse = 1'b0;
    reg sq_q1 = 1'b0, sq_q2 = 1'b0, sq_q3 = 1'b0;
    always @(posedge sq_clk or negedge rst_n) begin
        if (!rst_n) sq_reload_pulse <= 1'b0;
        else        sq_reload_pulse <= sq_reload_src;
    end
    always @(posedge sq_reload_pulse or negedge rst_n) begin
        if (!rst_n) sq_q1 <= 1'b0; else sq_q1 <= ~sq_q1;
    end
    always @(posedge sq_q1 or negedge rst_n) begin
        if (!rst_n) sq_q2 <= 1'b0; else sq_q2 <= ~sq_q2;
    end
    always @(posedge sq_q2 or negedge rst_n) begin
        if (!rst_n) sq_q3 <= 1'b0; else sq_q3 <= ~sq_q3;
    end

    // 占空比组合 + 选通 (HC08 AND + HC153 4选1)
    wire sq_d50   = sq_q1;
    wire sq_d25   = sq_q1 & sq_q2;
    wire sq_d125  = sq_q1 & sq_q2 & sq_q3;
    wire sq_d25f4 = sq_q2 & sq_q3;
    reg sq_wave_sel;
    always @(*) begin
        case (sq_duty)
            2'b00: sq_wave_sel = sq_d50;
            2'b01: sq_wave_sel = sq_d25;
            2'b10: sq_wave_sel = sq_d125;
            2'b11: sq_wave_sel = sq_d25f4;
        endcase
    end

    // TLC7524 衰减器 (方波)
    assign sq_audio = sq_wave_sel ? (sq_vol << 4) : 8'd0;

    // ============================================================
    // 波形通道 CH2 (v0.5 新, clk=4MHz 直连)
    //   一个 CD4029 4-bit 计数器, wave_sel 切换波形, HC85 比较器一直在线.
    // ============================================================
    wire [11:0] uni_period = {reg4_q[7:4], reg3_q};      // period12 (reg3低8 + reg4高4)
    wire [3:0]  uni_vol     = reg4_q[3:0];                // vol4
    wire [3:0]  uni_duty    = reg5_q[3:0];                // duty4 (bit0-3, 比较阈值/AND掩码)
    wire        uni_mode    = reg5_q[4];                  // mode_sel (bit4, 1=比较 0=AND)
    wire [1:0]  uni_wave    = reg5_q[6:5];                // wave_sel (bit5-6, 00锯01三10方11反)
    // reg5[7] 预留

    // ---- 12-bit period 上计数器 (3×HC161, TC→PE reload) ----
    wire uni_freq_tc, uni_pe_n;
    wire       uni_tc_lo, uni_tc_mid;
    wire [3:0] uni_cnt_lo, uni_cnt_mid, uni_cnt_hi;
    hc161 u_up0 (.MR(rst_n), .CP(clk),
        .D0(uni_period[0]),.D1(uni_period[1]),.D2(uni_period[2]),.D3(uni_period[3]),
        .Q0(uni_cnt_lo[0]),.Q1(uni_cnt_lo[1]),.Q2(uni_cnt_lo[2]),.Q3(uni_cnt_lo[3]),
        .CEP(1'b1),.CET(1'b1),.PE(uni_pe_n),.TC(uni_tc_lo));
    hc161 u_up1 (.MR(rst_n), .CP(clk),
        .D0(uni_period[4]),.D1(uni_period[5]),.D2(uni_period[6]),.D3(uni_period[7]),
        .Q0(uni_cnt_mid[0]),.Q1(uni_cnt_mid[1]),.Q2(uni_cnt_mid[2]),.Q3(uni_cnt_mid[3]),
        .CEP(uni_tc_lo),.CET(uni_tc_lo),.PE(uni_pe_n),.TC(uni_tc_mid));
    hc161 u_up2 (.MR(rst_n), .CP(clk),
        .D0(uni_period[8]),.D1(uni_period[9]),.D2(uni_period[10]),.D3(uni_period[11]),
        .Q0(uni_cnt_hi[0]),.Q1(uni_cnt_hi[1]),.Q2(uni_cnt_hi[2]),.Q3(uni_cnt_hi[3]),
        .CEP(uni_tc_mid),.CET(uni_tc_mid),.PE(uni_pe_n),.TC(uni_freq_tc));
    hc00 u_pe_nand (
        .A1(uni_freq_tc),.B1(uni_freq_tc),.Y1(uni_pe_n),
        .A2(1'b0),.B2(1'b0),.Y2(), .A3(1'b0),.B3(1'b0),.Y3(), .A4(1'b0),.B4(1'b0),.Y4());
    assign uni_tc = uni_freq_tc;

    // ---- CD4029 16步波形计数器 (CI=~freq_tc, freq_tc 时走一步) ----
    wire uni_ci = ~uni_freq_tc;
    wire uni_co;
    wire [3:0] uni_q;
    wire uni_ud;

    cd4029 u_wave (
        .PE(1'b0), .CI(uni_ci), .BD(1'b1), .UD(uni_ud), .CLK(clk),
        .JAM1(1'b0),.JAM2(1'b0),.JAM3(1'b0),.JAM4(1'b0),
        .Q1(uni_q[0]),.Q2(uni_q[1]),.Q3(uni_q[2]),.Q4(uni_q[3]),
        .CO(uni_co));

    // ---- 74HC112 方向控制 (折返开关, 下降沿触发) ----
    // CD4027 不在库存, 用 74HC112 (库存有). 112 是下降沿触发, 直接接 clk (不需反相).
    // wave_sel[0]=fold: 1=三角(112折返30步), 0=锯齿族(单向16步)
    // wave_sel[1]=dir:  0=加(锯齿/方波), 1=减(反锯齿). fold=1时dir无效(三角对称)
    wire uni_clk_n = ~clk;  // 给 HC273 用 (HC273 上升沿, 要 ~clk 下降沿采样)
    // at_extreme: freq_tc & ~CO. 但 CO 真值表已含 CI 条件 (CO=L 当 CI=L 且极值),
    // CI=~freq_tc, 所以 ~CO=H 已隐含 freq_tc=H. 真硬件可直接用 ~CO 当 at_extreme (省 AND 门).
    wire at_extreme = uni_freq_tc & ~uni_co;
    wire dir_q, dir_qn;
    hc112 u_dir (
        .CLK1_n(clk), .J1(at_extreme), .K1(at_extreme),
        .PRE1_n(1'b1), .CLR1_n(rst_n),   // PRE无效(H), CLR=rst_n(低有效复位)
        .Q1(dir_q), .Q1_n(dir_qn),
        .CLK2_n(1'b1), .J2(1'b0), .K2(1'b0), .PRE2_n(1'b1), .CLR2_n(1'b1),
        .Q2(), .Q2_n());
    // UD 选择 (fold=三角折返, 否则按 dir):
    //   wave_sel=01(fold=1,三角): UD=dir_qn (112 折返, 30步)
    //   wave_sel=11(dir=1,反锯齿): UD=0 (单向减, 16步)
    //   wave_sel=00/10(dir=0,锯齿/方波): UD=1 (单向加, 16步)
    // 真硬件: U32 HC00 用 3 个 NAND 门做 2选1 mux: uni_ud = fold ? dir_qn : ~dir
    //   (需要 ~fold, ~dir 由 U23 HC00 反相器组提供)
    assign uni_ud = (uni_wave == 2'b01) ? dir_qn :
                    (uni_wave == 2'b11) ? 1'b0 : 1'b1;

    // ---- HC273 毛刺滤除 (4-bit, clk 反相沿锁存) ----
    wire [3:0] uni_wave_clean;
    hc273 #(.WIDTH(4)) u_filter (
        .MR_n(rst_n), .CP(uni_clk_n),
        .D(uni_q), .Q(uni_wave_clean));

    // ---- 比较器 (counter vs duty4) → 比较输出 (阈值调制) ----
    // HC85 不在库存, 用 74HC283 (4位加法器) 做 duty-counter 减法看进位.
    // 硬件: A=duty, B=~counter, C0=1 → duty + (~counter+1) = duty-counter.
    //   C4(进位)=1 → duty>=counter (无借位). RTL 等效 < 比较:
    wire uni_altb;   // counter < duty
    assign uni_altb = (uni_wave_clean < uni_duty) ? 1'b1 : 1'b0;
    wire [3:0] uni_cmp_out = {4{uni_altb}};   // 比较结果: 全1或全0

    // ---- HC08 AND (counter AND duty4) → AND输出 (位掩码调制) ----
    wire [3:0] uni_and_out = uni_wave_clean & uni_duty;

    // ---- HC157 四 2选1: mode_sel 选比较/AND, 所有波形统一 (无特殊判断) ----
    // HC157: Select=1 → Y=B, Select=0 → Y=A.
    // mode_sel=1 → 选 B(比较输出 C4 广播4位, 阈值调制, 锯齿+比较=方波)
    // mode_sel=0 → 选 A(AND 输出, 位掩码, duty=15 时 = 原始波形)
    // ⚠️ 必须用 HC157 (四 2选1, 4个Y输出), 不是 HC153 (双4选1, 仅2个Y输出).
    wire [3:0] uni_sel;
    hc157 u_unimux (
        .Select(uni_mode),      // P1: mode_sel (R5.Q4)
        .A1(uni_and_out[0]), .B1(uni_cmp_out[0]),   // P2,P3
        .A2(uni_and_out[1]), .B2(uni_cmp_out[1]),   // P5,P6
        .A3(uni_and_out[2]), .B3(uni_cmp_out[2]),   // P13,P14
        .A4(uni_and_out[3]), .B4(uni_cmp_out[3]),   // P10,P11
        .Enable_n(1'b0),       // P15: 常开
        .Y1(uni_sel[0]), .Y2(uni_sel[1]),           // P4,P7
        .Y3(uni_sel[2]), .Y4(uni_sel[3])            // P9,P12
    );

    // ---- TLC7524 #1 波形生成 (DB4-7=sel, REF=5V) ----
    wire [7:0] uni_wave_db = {uni_sel, 4'b0000};

    // ---- TLC7524 #2 音量衰减 (DB4-7=vol, REF=#1输出) ----
    wire [15:0] uni_atten = uni_wave_db * {uni_vol, 4'b0000};
    assign uni_audio = uni_atten[15:8];

    // ============================================================
    // 噪音通道 CH1 (v0.4 原样保留, ctrl 从 reg2 取, clk=sq_clk)
    // ============================================================
    wire [3:0] nz_vol     = reg2_q[3:0];
    wire [1:0] nz_freq    = reg2_q[5:4];
    wire       nz_bind    = reg2_q[6];

    wire [3:0] nz_div_q;
    wire       nz_div_tc;
    hc161 u_div161 (.MR(1'b1), .CP(sq_clk),
        .D0(1'b0),.D1(1'b0),.D2(1'b0),.D3(1'b0),
        .Q0(nz_div_q[0]),.Q1(nz_div_q[1]),.Q2(nz_div_q[2]),.Q3(nz_div_q[3]),
        .CEP(1'b1),.CET(1'b1),.PE(1'b1),.TC(nz_div_tc));

    wire nz_ind_clk;
    hc153 u_nzmux (
        .A(nz_freq[0]), .B(nz_freq[1]), ._1G_n(1'b0),
        ._1C0(nz_div_q[0]), ._1C1(nz_div_q[1]),
        ._1C2(nz_div_q[2]), ._1C3(nz_div_q[3]), ._1Y(nz_ind_clk),
        ._2G_n(1'b1), ._2C0(1'b0),._2C1(1'b0),._2C2(1'b0),._2C3(1'b0), ._2Y());

    wire nz_clk = nz_bind ? sq_tc : nz_ind_clk;  // 绑定用方波 TC (sq_tc)

    reg [7:0] lfsr_q = 8'h00;
    reg [7:0] lfsr_d;
    reg [4:0] nz_startup = 5'd0;
    wire      nz_starting = (nz_startup < 5'd16);
    wire xor_a = lfsr_q[7] ^ lfsr_q[5];
    wire xor_b = lfsr_q[4] ^ lfsr_q[3];
    wire nz_feedback = xor_a ^ xor_b;
    assign lfsr_d[0] = nz_starting ? 1'b1 : nz_feedback;
    assign lfsr_d[1] = lfsr_q[0];
    assign lfsr_d[2] = lfsr_q[1];
    assign lfsr_d[3] = lfsr_q[2];
    assign lfsr_d[4] = lfsr_q[3];
    assign lfsr_d[5] = lfsr_q[4];
    assign lfsr_d[6] = lfsr_q[5];
    assign lfsr_d[7] = lfsr_q[6];
    always @(posedge nz_clk) begin
        lfsr_q <= lfsr_d;
        if (nz_starting) nz_startup <= nz_startup + 5'd1;
    end
    assign nz_audio = lfsr_q[7] ? (nz_vol << 4) : 8'd0;

endmodule
