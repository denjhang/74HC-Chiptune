// sq_top.v — 一通道可调频率方波 (16位可编程分频器 + T触发器 + SPFM总线)
//
// 架构: 经典 161 可编程分频器 + SPFM 总线接口
//   - SPFM 总线 (373+174+377) 接收主机写入, 输出 reg_addr/reg_data
//   - 主机协议: 先写 addr=0/1 (A0=0), 再写 data (A0=1) 触发 data_wr
//     addr=0 → 写低字节, addr=1 → 写高字节
//   - 4 片 74HC161 串成 16 位计数器, 预置值 = FREQ
//   - TC 上升沿触发 74HC74 (T 触发器) 输出 50% 方波
//
// 频率公式 (主时钟 = SPFM_CLK, 标准 PSG = 1.789773 MHz):
//   f_out = SPFM_CLK / [2 × (65536 - FREQ)]
//
// C4 261.6 Hz @ 1.789773 MHz: FREQ = 65536 - 3419 = 0xF2A5
//
// 输出: sq_out 直接接喇叭 (经耦合电容), 无需 DAC
//
// 芯片清单:
//   SPFM 总线  (3): 373, 174, 377   (在 wt_spfm_bus.v)
//   频率字锁存 (2): 377 ×2
//   计数器     (4): 161 ×4
//   T 触发器   (1): 74
//   门电路     (2): 04 + 32
//   合计      12 IC

`timescale 1ns/1ps

module sq_top (
    input  wire        SPFM_CLK,
    input  wire        SPFM_RST_n,
    input  wire [7:0]  SPFM_D,
    input  wire        SPFM_A0,
    input  wire        SPFM_CS_n,
    input  wire        SPFM_WR_n,
    input  wire        SPFM_RD_n,

    output wire        sq_out
);

    // ============================================================
    // SPFM 总线接口 (3 IC, 实现在 wt_spfm_bus.v)
    //   输出: addr_wr_n / data_wr_n (active-low, 直接来自译码 ROM)
    // ============================================================
    wire [7:0] reg_addr;
    wire [7:0] reg_data;
    wire       addr_wr_n;
    wire       data_wr_n;
    wire       le_unused;

    wt_spfm_bus u_spfm (
        .CLK(SPFM_CLK), .RST_n(SPFM_RST_n),
        .D(SPFM_D), .A0(SPFM_A0),
        .CS_n(SPFM_CS_n), .WR_n(SPFM_WR_n), .RD_n(SPFM_RD_n),
        .reg_addr(reg_addr), .reg_data(reg_data),
        .addr_wr_n(addr_wr_n), .data_wr_n(data_wr_n),
        .le(le_unused)
    );

    // ============================================================
    // hc377 × 2: 频率字寄存器 (2 IC)
    //   data_wr_n=0 (写数据激活) + reg_addr[0] 选择低/高字节
    //   Enable_bar 为 0 (有效) 当且仅当: data_wr_n=0 且地址匹配
    //     lo_en_bar = data_wr_n | reg_addr[0]     (data_wr_n=0 且 addr=0 → 0)
    //     hi_en_bar = data_wr_n | ~reg_addr[0]    (data_wr_n=0 且 addr=1 → 0)
    //
    //   用 hc04 + hc32 译码:
    //     a0n = ~reg_addr[0]              (hc04)
    //     lo_en_bar = data_wr_n | addr0   (hc32)
    //     hi_en_bar = data_wr_n | a0n     (hc32)
    // ============================================================
    wire [7:0] freq_lo;
    wire [7:0] freq_hi;

    wire a0n;   // ~reg_addr[0]
    wire lo_en_bar;
    wire hi_en_bar;

    hc377 u_freq_lo (
        .Enable_bar(lo_en_bar),
        .D(reg_data),
        .Clk(SPFM_CLK),
        .Q(freq_lo)
    );

    hc377 u_freq_hi (
        .Enable_bar(hi_en_bar),
        .D(reg_data),
        .Clk(SPFM_CLK),
        .Q(freq_hi)
    );

    wire [15:0] freq = {freq_hi, freq_lo};

    // ============================================================
    // hc04: 反相器 (1 IC, 用 2 路)
    //   A1=tc3          Y1=pe_n     (16位全1时拉低 PE, 重新预置)
    //   A2=reg_addr[0]  Y2=a0n
    //   其余 4 路输入绑 0 (闲置)
    //   (原 A2=data_wr 反相已不需要: data_wr_n 直接来自总线)
    // ============================================================
    wire pe_n;
    wire _unused_inv3, _unused_inv4, _unused_inv5, _unused_inv6;
    wire [3:0] q0, q1, q2, q3;
    wire       tc0, tc1, tc2, tc3;

    hc04 u_inv (
        .A1(tc3),         .Y1(pe_n),
        .A2(reg_addr[0]), .Y2(a0n),
        .A3(1'b0), .Y3(_unused_inv3),
        .A4(1'b0), .Y4(_unused_inv4),
        .A5(1'b0), .Y5(_unused_inv5),
        .A6(1'b0), .Y6(_unused_inv6)
    );

    // ============================================================
    // hc32: 译码 Enable_bar (1 IC, 用 2 路)
    //   Y1 = data_wr_n | reg_addr[0] → lo_en_bar
    //   Y2 = data_wr_n | a0n         → hi_en_bar
    //   其余 2 路绑 0
    // ============================================================
    wire _unused_or3, _unused_or4;

    hc32 u_or (
        .A1(data_wr_n),  .B1(reg_addr[0]), .Y1(lo_en_bar),
        .A2(data_wr_n),  .B2(a0n),         .Y2(hi_en_bar),
        .A3(1'b0), .B3(1'b0), .Y3(_unused_or3),
        .A4(1'b0), .B4(1'b0), .Y4(_unused_or4)
    );

    // ============================================================
    // hc161 × 4: 16 位可编程计数器 (4 IC)
    //   级联: 低位 TC 驱动高位 CEP/CET
    //   预置: 全 16 位 = 1111...1 时 TC3=1, pe_n=0, 下一时钟预置 FREQ
    // ============================================================
    hc161 u_cnt0 (
        .MR(1'b1), .CP(SPFM_CLK),
        .D0(freq[0]),  .D1(freq[1]),  .D2(freq[2]),  .D3(freq[3]),
        .Q0(q0[0]), .Q1(q0[1]), .Q2(q0[2]), .Q3(q0[3]),
        .CEP(1'b1), .CET(1'b1), .PE(pe_n), .TC(tc0)
    );

    hc161 u_cnt1 (
        .MR(1'b1), .CP(SPFM_CLK),
        .D0(freq[4]),  .D1(freq[5]),  .D2(freq[6]),  .D3(freq[7]),
        .Q0(q1[0]), .Q1(q1[1]), .Q2(q1[2]), .Q3(q1[3]),
        .CEP(tc0), .CET(tc0), .PE(pe_n), .TC(tc1)
    );

    hc161 u_cnt2 (
        .MR(1'b1), .CP(SPFM_CLK),
        .D0(freq[8]),  .D1(freq[9]),  .D2(freq[10]), .D3(freq[11]),
        .Q0(q2[0]), .Q1(q2[1]), .Q2(q2[2]), .Q3(q2[3]),
        .CEP(tc1), .CET(tc1), .PE(pe_n), .TC(tc2)
    );

    hc161 u_cnt3 (
        .MR(1'b1), .CP(SPFM_CLK),
        .D0(freq[12]), .D1(freq[13]), .D2(freq[14]), .D3(freq[15]),
        .Q0(q3[0]), .Q1(q3[1]), .Q2(q3[2]), .Q3(q3[3]),
        .CEP(tc2), .CET(tc2), .PE(pe_n), .TC(tc3)
    );

    // ============================================================
    // hc74: T 触发器 (1 IC, 用一半)
    //   TC3 上升沿 → Q 翻转 → 输出 50% 方波
    //   D = Q_n, 时钟 = TC3, PRE=CLR=1 (无效)
    // ============================================================
    wire sq_q, sq_q_n;

    hc74 u_tff (
        .CLR1(1'b1), .CLK1(tc3), .D1(sq_q_n), .PRE1(1'b1),
        .Q1(sq_q),   .Q1_n(sq_q_n),
        .CLR2(1'b1), .CLK2(1'b0), .D2(1'b0), .PRE2(1'b1),
        .Q2(),       .Q2_n()
    );

    assign sq_out = sq_q;

endmodule
