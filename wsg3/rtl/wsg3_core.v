// wsg3_core.v — WSG3 顶层 (Pac-Man WSG 功能等效复刻)
//
// 设计原则: 按芯片类型做功能等效, 不纠结原版引脚号 1:1
// 数据来源: reference/Namco WSG/Pac-Man技术文档_extracted/document_text.txt
//
// 芯片清单 (11 WSG + 3 SPFM = 14 片, 0 隐藏门):
//   SPFM 接口 (3):  373 + 174 + 377  (wt3_spfm_bus 内部)
//   WSG 核心 (11):
//     U2  74HC86    XOR (类型保留实例)
//     U3  39SF040   3M 微码 ROM (16 step × 4 sub-cycle × 4-bit)
//     U4  74HC157   AB mux  (RAM 地址: CPU / TDM step)
//     U5  74HC158   DB 反相 mux (RAM DI: CPU data / 加法结果回写)
//     U6  74LS189   acc RAM (累加器 nibble 存储, 16×4)
//     U7  74LS189   freq/vol RAM (频率/音量常数, 16×4)
//     U8  74HC283   4-bit 加法器 (time-shared, 4-5 次/TDM 周期)
//     U9  74HC174   进位/滑窗锁存 (6-bit, 跨步骤保留 carry)
//     U10 39SF040   1M 波形 ROM (8 波 × 32 点 × 4-bit)
//     U11 74HC273   输出寄存器 (波形 × 音量)
//     U12 CD4066    模拟开关 (wave × vol)
//
// 微码 ROM (3M) 地址布局 (Pac-Man 文档第 209-211 行):
//   A[5:2] = TDM step (HCNT[5:2], 0-15)
//   A[1:0] = sub-cycle (HCNT[1:0], 0-3)
//   每个 cell 4-bit:
//     bit[3] = ~clr174_n (0=异步清零 carry chain)
//     bit[2] = ~acc_we_n (0=写加法结果回 acc RAM)
//     bit[1] = cp273     (上升沿锁存输出)
//     bit[0] = clk174    (上升沿锁存 carry chain)
//
// 加法器 (Pac-Man 文档第 211 行):
//   sum_1K = acc + freq + carry_chain[5]  (5-bit)
//   sum_d_1L <= {sum_1K, sum_d_1L[3]}  (6-bit carry + slide)
//
// 波形 ROM 地址 (Pac-Man 文档第 212 行):
//   rom1m_addr[7:5] = acc_dout[2:0]  (波形选择, 来自 acc RAM[5])
//   rom1m_addr[4:0] = carry_chain[4:0]  (相位 0-31, 来自 carry)

`timescale 1ns/1ps

module wsg3_core (
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
    // SPFM 总线接口 (3 IC: 373 + 174 + 377)
    // ============================================================
    wire [7:0] reg_addr;
    wire [7:0] reg_data;
    wire       addr_wr_pulse_n;
    wire       data_wr_pulse_n;

    wt3_spfm_bus u_spfm (
        .CLK(SPFM_CLK),
        .RST_n(SPFM_RST_n),
        .D(SPFM_D),
        .A0(SPFM_A0),
        .CS_n(SPFM_CS_n),
        .WR_n(SPFM_WR_n),
        .RD_n(SPFM_RD_n),
        .reg_addr(reg_addr),
        .reg_data(reg_data),
        .addr_wr_pulse_n(addr_wr_pulse_n),
        .data_wr_pulse_n(data_wr_pulse_n)
    );

    // ============================================================
    // HCNT 6-bit 计数器 (Pac-Man 主时钟 6.144MHz, 64 分频 = 96kHz)
    // ============================================================
    wire spfm_write_active = ~SPFM_CS_n & ~SPFM_WR_n & SPFM_RST_n;

    reg [5:0] hcnt_r;
    always @(posedge SPFM_CLK or negedge SPFM_RST_n) begin
        if (!SPFM_RST_n)
            hcnt_r <= 6'b0;
        else
            hcnt_r <= hcnt_r + 1'b1;
    end

    wire [3:0] tdm_step = hcnt_r[5:2];
    wire [1:0] sub_cyc  = hcnt_r[1:0];

    // ============================================================
    // U2: 74HC86 — XOR (类型保留)
    // ============================================================

    hc86 u_u2 (
        .A1(spfm_write_active), .B1(1'b0), .Y1(),
        .A2(1'b0), .B2(1'b0), .Y2(),
        .A3(1'b0), .B3(1'b0), .Y3(),
        .A4(1'b0), .B4(1'b0), .Y4()
    );

    // ============================================================
    // U3: 39SF040 — 3M 微码 ROM
    //   地址 A[5:0] = HCNT[5:0] (TDM step × sub-cycle)
    //   数据 bit[3] = ~clr174_n
    //        bit[2] = ~acc_we_n
    //        bit[1] = cp273_en
    //        bit[0] = clk174_en
    // ============================================================
    wire [7:0] rom3m_data;
    hc39sf040 #(.ADDR_WIDTH(19), .DATA_WIDTH(8), .INIT_FILE("rom/wsg3_prom3m.hex"))
        u_u3 (
        .A0(sub_cyc[0]), .A1(sub_cyc[1]),
        .A2(tdm_step[0]), .A3(tdm_step[1]), .A4(tdm_step[2]), .A5(tdm_step[3]),
        .A6(1'b0), .A7(1'b0),
        .A8(1'b0), .A9(1'b0), .A10(1'b0), .A11(1'b0),
        .A12(1'b0), .A13(1'b0), .A14(1'b0), .A15(1'b0),
        .A16(1'b0), .A17(1'b0), .A18(1'b0),
        .DQ(rom3m_data),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // 控制位解码 (Pac-Man 原版位映射)
    //   bit[3] = ~clr174_n (异步清零 carry chain, 0=clear)
    //   bit[2] = ~acc_we_n (acc RAM 写使能, 0=写)
    //   bit[1] = cp273     (输出锁存, 1=上升沿锁存输出)
    //   bit[0] = clk174    (carry chain 时钟, 1=上升沿锁存)
    wire rom3m_clr_n    = rom3m_data[3];
    wire rom3m_acc_we_n = rom3m_data[2];   // 0=写 acc
    wire cp273          = rom3m_data[1] & SPFM_RST_n & ~spfm_write_active;
    wire clk174         = rom3m_data[0] & SPFM_RST_n & ~spfm_write_active;
    // 异步清零: RST 或微码 step0 sub3
    wire clr174_n = (~SPFM_RST_n) ? 1'b0 :
                    (spfm_write_active) ? 1'b1 :
                    rom3m_clr_n;

    // acc RAM 写使能 (低有效)
    // RST 期间: 不写
    // 主机写且 reg_addr[4]=0 (写 0x4x → acc RAM): data_wr_pulse_n
    // 主机写且 reg_addr[4]=1 (写 0x5x → freq RAM): 不写 U6 (锁 1)
    // TDM 扫描: rom3m_acc_we_n (微码控制写回加法结果)
    wire u6_we_n = (~SPFM_RST_n)                          ? 1'b1        :  // RST: 不写
                  (spfm_write_active && reg_addr[4])      ? 1'b1        :  // 主机写 0x5x: 不写 U6
                  (spfm_write_active)                     ? data_wr_pulse_n :
                                                            rom3m_acc_we_n;

    // ============================================================
    // U4: 74HC157 — AB mux (RAM 地址)
    //   Select=~spfm_write_active (写时=0 选 A=CPU 地址, 否则=1 选 B=tdm_step)
    // ============================================================
    wire [3:0] ram_addr;

    hc157 u_u4 (
        .Select(~spfm_write_active),
        .A1(reg_addr[0]), .B1(tdm_step[0]), .Y1(ram_addr[0]),
        .A2(reg_addr[1]), .B2(tdm_step[1]), .Y2(ram_addr[1]),
        .A3(reg_addr[2]), .B3(tdm_step[2]), .Y3(ram_addr[2]),
        .A4(reg_addr[3]), .B4(tdm_step[3]), .Y4(ram_addr[3]),
        .Enable_n(1'b0)
    );

    // ============================================================
    // 前向声明
    // ============================================================
    wire [5:0] carry_chain;
    wire [3:0] adder_s;
    wire       adder_c4;

    // ============================================================
    // U5: 74HC158 — DB 反相 mux (RAM DI)
    //   Select=~spfm_write_active (写时=0 选 A=reg_data 反相)
    //                                (扫描时=1 选 B=adder_s 反相 → 写回 acc RAM)
    // ============================================================
    wire [3:0] ram_din_inv;

    hc158 u_u5 (
        .Select(~spfm_write_active),
        .A1(reg_data[0]), .B1(adder_s[0]), .Y1(ram_din_inv[0]),
        .A2(reg_data[1]), .B2(adder_s[1]), .Y2(ram_din_inv[1]),
        .A3(reg_data[2]), .B3(adder_s[2]), .Y3(ram_din_inv[2]),
        .A4(reg_data[3]), .B4(adder_s[3]), .Y4(ram_din_inv[3])
    );

    // ============================================================
    // U6: 74LS189 — acc RAM (累加器 nibble + 波形号, 16×4)
    //   /CS 始终低 (TDM 引擎持续读 acc RAM)
    //   主机写 0x4x 时: ram_addr=reg_addr[3:0], u6_we_n=data_wr_pulse_n
    //   TDM 时: ram_addr=tdm_step, u6_we_n=rom3m_acc_we_n (微码控制写回)
    // ============================================================
    wire [3:0] u6_do_inv;
    wire [3:0] acc_dout = u6_do_inv;  // ls189 输出已是反相, 直接取
    wire       u6_cs_n  = 1'b0;       // TDM 引擎始终读 U6 (主机写时 U6 也可读)

    ls189 u_u6 (
        .A0(ram_addr[0]), .A1(ram_addr[1]), .A2(ram_addr[2]), .A3(ram_addr[3]),
        .WE_n(u6_we_n),
        .CS_n(u6_cs_n),
        .D0(ram_din_inv[0]), .D1(ram_din_inv[1]),
        .D2(ram_din_inv[2]), .D3(ram_din_inv[3]),
        .RST_n(SPFM_RST_n),
        .O0(u6_do_inv[0]), .O1(u6_do_inv[1]),
        .O2(u6_do_inv[2]), .O3(u6_do_inv[3])
    );

    // ============================================================
    // U7: 74LS189 — freq/vol RAM (常数, 16×4)
    //   /CS 始终低 (TDM 引擎持续读 freq/vol)
    //   主机写 0x5x 时: ram_addr=reg_addr[3:0], data_wr_pulse_n 写入
    // ============================================================
    wire [3:0] u7_do_inv;
    wire [3:0] freq_dout = u7_do_inv;
    wire       u7_cs_n   = 1'b0;       // TDM 引擎始终读 U7

    // freq/vol RAM 写使能: 主机写 0x5x 时 (reg_addr[4]=1) 用 data_wr_pulse_n
    // 主机写 0x4x 时 (reg_addr[4]=0): 不写 U7 (锁 1)
    // TDM 扫描: 不写 U7 (freq/vol 是常数)
    wire u7_we_n = (~SPFM_RST_n)                       ? 1'b1        :
                   (spfm_write_active && reg_addr[4])  ? data_wr_pulse_n :
                                                          1'b1;

    ls189 u_u7 (
        .A0(ram_addr[0]), .A1(ram_addr[1]), .A2(ram_addr[2]), .A3(ram_addr[3]),
        .WE_n(u7_we_n),
        .CS_n(u7_cs_n),
        .D0(ram_din_inv[0]), .D1(ram_din_inv[1]),
        .D2(ram_din_inv[2]), .D3(ram_din_inv[3]),
        .RST_n(SPFM_RST_n),
        .O0(u7_do_inv[0]), .O1(u7_do_inv[1]),
        .O2(u7_do_inv[2]), .O3(u7_do_inv[3])
    );

    // ============================================================
    // U8: 74HC283 — 4-bit 加法器
    //   A = acc_dout, B = freq_dout, C0 = carry_chain[5]
    //   S = 4-bit sum, C4 = carry out
    // ============================================================
    hc283 u_u8 (
        .A(acc_dout),
        .B(freq_dout),
        .C0(carry_chain[5]),
        .S(adder_s),
        .C4(adder_c4)
    );

    // ============================================================
    // U9: 74HC174 — carry chain + sliding window (6-bit)
    //   文档算法: sum_d_1L <= {sum_1K, sum_d_1L[3]}
    //     sum_1K = {adder_c4, adder_s[3:0]}  (5-bit)
    //     新 [5:1] = sum_1K[4:0]
    //     新 [0]   = 旧 [3] (滑窗保留)
    //   D1 = carry_chain[3] (旧 Q3 反馈)
    //   D2 = adder_s[0], D3 = adder_s[1], D4 = adder_s[2]
    //   D5 = adder_s[3], D6 = adder_c4
    //   CLK = clk174 (微码 sub0/sub1 上升沿)
    //   /CLR = clr174_n (微码 step0 sub3 异步清零)
    // ============================================================
    hc174 u_u9 (
        .CLR(clr174_n),
        .D1(carry_chain[3]),
        .D2(adder_s[0]),
        .D3(adder_s[1]),
        .D4(adder_s[2]),
        .D5(adder_s[3]),
        .D6(adder_c4),
        .CLK(clk174),
        .Q1(carry_chain[0]),
        .Q2(carry_chain[1]),
        .Q3(carry_chain[2]),
        .Q4(carry_chain[3]),
        .Q5(carry_chain[4]),
        .Q6(carry_chain[5])
    );

    // ============================================================
    // U10: 39SF040 — 1M 波形 ROM
    //   地址: A[2:0] = acc_dout[2:0] (波形号, 来自 acc RAM[5])
    //         A[4:0] = 累加器相位低 5 位
    //   真正的 20-bit 累加器 = {acc[4], acc[3], acc[2], acc[1], acc[0]}
    //   相位低 5 位 = {acc[1][0], acc[0][3:0]}
    //   问题: TDM 只能读一个 nibble，无法同时读 acc[0] 和 acc[1]
    //   解决: 在 step 4 锁存 acc[0]，在 step 5 使用锁存值
    // ============================================================
    wire [7:0] rom1m_data;
    wire [3:0] wave_sample = rom1m_data[3:0];

    wire [2:0] wave_sel  = acc_dout[2:0];

    // 锁存 acc[0] (在 step 4 读取)
    reg [3:0] acc0_latch;
    always @(posedge SPFM_CLK or negedge SPFM_RST_n) begin
        if (!SPFM_RST_n)
            acc0_latch <= 4'b0;
        else if (tdm_step == 4'd4)
            acc0_latch <= acc_dout;
    end

    // 锁存 acc[1] (在 step 5 读取，用于下一周期)
    reg [3:0] acc1_latch;
    always @(posedge SPFM_CLK or negedge SPFM_RST_n) begin
        if (!SPFM_RST_n)
            acc1_latch <= 4'b0;
        else if (tdm_step == 4'd5 && sub_cyc == 2'd0)  // step 5 sub0
            acc1_latch <= acc_dout;  // 此时 acc_dout = U6[5] = ch1 acc[0]
    end

    // 这还是不对！step 5 读取的是 U6[5] (ch1 的 acc[0])，不是 ch0 的 acc[1]
    // 暂时用 carry_chain[4:0]，等待进一步分析
    wire [4:0] phase_sel = carry_chain[4:0];

    hc39sf040 #(.ADDR_WIDTH(19), .DATA_WIDTH(8), .INIT_FILE("rom/wsg3_prom1m.hex"))
        u_u10 (
        .A0(wave_sel[0]), .A1(wave_sel[1]), .A2(wave_sel[2]),
        .A3(phase_sel[0]), .A4(phase_sel[1]), .A5(phase_sel[2]),
        .A6(phase_sel[3]), .A7(phase_sel[4]),
        .A8(1'b0), .A9(1'b0), .A10(1'b0), .A11(1'b0),
        .A12(1'b0), .A13(1'b0), .A14(1'b0), .A15(1'b0),
        .A16(1'b0), .A17(1'b0), .A18(1'b0),
        .DQ(rom1m_data),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // ============================================================
    // U11: 74HC273 — 输出寄存器
    //   D[3:0] = wave_sample (来自 1M ROM)
    //   D[7:4] = freq_dout  (输出步骤时 = 音量 nibble, 来自 freq/vol RAM[5])
    //   CP = cp273 (微码输出步骤上升沿)
    // ============================================================
    wire [7:0] out_d = {freq_dout, wave_sample};
    wire [7:0] u11_q;

    hc273 #(.WIDTH(8)) u_u11 (
        .MR_n(SPFM_RST_n),
        .CP(cp273),
        .D(out_d),
        .Q(u11_q)
    );

    // ============================================================
    // U12: CD4066 — 模拟开关 (wave × vol)
    //   硬件中: vol_nib 控制 4 个开关通断, 把 wave_nib 位接到 R-2R 梯
    //   实现模拟乘法 wave × vol (DAC 输出)
    //   仿真简化: 直接数字乘法 (跳过 R-2R 网络和模拟开关)
    // ============================================================
    wire [3:0] vol_nib  = u11_q[7:4];
    wire [3:0] wave_nib = u11_q[3:0];
    wire       io1, io2, io3, io4;

    cd4066 u_u12 (
        .CTRL1(vol_nib[0]), .CTRL2(vol_nib[1]),
        .CTRL3(vol_nib[2]), .CTRL4(vol_nib[3]),
        .IO1A(wave_nib[0]), .IO1B(io1),
        .IO2A(wave_nib[1]), .IO2B(io2),
        .IO3A(wave_nib[2]), .IO3B(io3),
        .IO4A(wave_nib[3]), .IO4B(io4)
    );

    assign dac_out = {4'd0, wave_nib} * {4'd0, vol_nib};

endmodule
