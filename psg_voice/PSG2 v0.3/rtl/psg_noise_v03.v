// psg_noise_v03.v — PSG2 v0.3 LFSR 白噪音通道 (CH1)
//
// 纯白噪音通道 (周期噪音经试听验证不可用, 已砍)。
// max-length 8 位 LFSR (Q7⊕Q5⊕Q4⊕Q3, 周期 255), 种子非0 永不自锁。
// 4 挡频率 (HC161 分频 64kHz, HC153 选通)。
// 4-bit 音量 (TLC7524 REF 携带波形)。
//
// 芯片清单 (6 片核心):
//   cd4070 x1 — 门1-3: 白噪反馈 Q7⊕Q5⊕Q4⊕Q3 (max-length 周期255); 门4: 闲置
//   hc164  x1 — 8-bit LFSR 主体 (Q0-Q7 全引出; MR 常接1, 靠 serial_in 灌种)
//   hc161  x1 — 自由计数分频 (64kHz ÷2/4/8/16, CEP/CET=1); 绑定模式不用它
//              绑定 2选1 (noise_clk = bind ? square_tc : ind_clk) 借 HC00 剩余门
//   hc153  x1 — 上半部 4 选 1 选频率挡; 下半部闲置 (2G_n=1)
//   hc374  x1 — 8 bit 控制寄存器
//   TLC7524   — 1-bit DAC (REF=噪音 Q7, DB4-7=音量)
//
// 死锁防护 (0 额外芯片): RST 期间 serial_in=1 持续灌种子。
//   硬件借方波通道 HC00 剩余门把 rst_n 反相, RST 时强制 serial_in=1。
//   白噪 max-length 性质: 种子非0 永不归零 (全1是过渡态, 非死锁)。
//
// 寄存器 (HC374, 8 bit):
//   bit0-3: 音量 (16 级, Q0-Q3 → DB4-7, 与方波风格统一)
//   bit4-5: 频率挡 (00=÷2 / 01=÷4 / 10=÷8 / 11=÷16)
//   bit6:   绑定开关 (0=独立 64kHz / 1=绑定方波 TC)
//   bit7:   预留

`timescale 1ns/1ps

module psg_noise_v03 (
    input        clk,         // 64kHz 全局晶振
    input        rst_n,
    input        A1,          // HC374 CP (写噪音控制寄存器, FT232H D7)
    input  [7:0] data,        // 复用数据总线
    input        square_tc,   // 方波通道 TC (绑定模式时钟源)
    output [7:0] audio_out    // TLC7524 衰减后噪音
);

    // ========== 控制寄存器 (HC374) ==========
    wire [7:0] ctrl_q;
    hc374 u_ctrl (.OE_n(1'b0), .CP(A1), .D(data), .Q(ctrl_q));

    wire [1:0] freq_sel = ctrl_q[5:4];   // 频率挡 (bit4-5)
    wire       bind_sw  = ctrl_q[6];     // 绑定开关 (bit6, 0=独立, 1=绑定方波)
    wire [3:0] vol      = ctrl_q[3:0];   // 音量 (bit0-3, Q0-Q3 → DB4-7)

    // ========== 独立分频器 (HC161, 64kHz ÷2/÷4/÷8/÷16) ==========
    wire [3:0] div_q;
    wire       div_tc;

    hc161 u_div161 (
        .MR(rst_n), .CP(clk),
        .D0(1'b0),.D1(1'b0),.D2(1'b0),.D3(1'b0),
        .Q0(div_q[0]),.Q1(div_q[1]),.Q2(div_q[2]),.Q3(div_q[3]),
        .CEP(1'b1),.CET(1'b1),.PE(1'b1),.TC(div_tc)
    );

    // ========== 频率选通 (HC153 上半部 4 选 1, 仅独立模式) ==========
    wire ind_clk;   // 独立模式分频时钟

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

    // ========== 绑定开关 2 选 1 (借 HC00 剩余门, 0 额外芯片) ==========
    // bind_sw=0: noise_clk = ind_clk (独立模式, HC161 分频)
    // bind_sw=1: noise_clk = square_tc (绑定模式, 噪音=2×方波频率, 音越高越密)
    // 硬件: HC00 4 门 (2 与非 + 1 反相 + 1 汇总):
    //   n1 = NAND(ind_clk, !bind_sw)
    //   n2 = NAND(square_tc, bind_sw)   (!bind_sw 用第3门当反相器)
    //   noise_clk = NAND(n1, n2)
    wire noise_clk = bind_sw ? square_tc : ind_clk;

    // ========== LFSR 反馈 (CD4070: max-length Q7⊕Q5⊕Q4⊕Q3, 周期255) ==========
    wire lfsr_q7, lfsr_q6, lfsr_q5, lfsr_q4;
    wire lfsr_q3, lfsr_q2, lfsr_q1, lfsr_q0;
    wire xor_a, xor_b, xor_fb;

    cd4070 u_xor (
        .A1(lfsr_q7), .B1(lfsr_q5), .Y1(xor_a),    // 门1: Q7⊕Q5
        .A2(lfsr_q4), .B2(lfsr_q3), .Y2(xor_b),    // 门2: Q4⊕Q3
        .A3(xor_a),   .B3(xor_b),   .Y3(xor_fb),   // 门3: (Q7⊕Q5)⊕(Q4⊕Q3)
        .A4(1'b0),    .B4(1'b0),    .Y4()          // 门4: 闲置
    );

    // ========== 死锁防护: RST 期间灌种子 (借 HC00 剩余门反相 RST) ==========
    wire serial_in = (!rst_n) ? 1'b1 : xor_fb;

    // ========== LFSR 主体 (HC164) ==========
    hc164 u_lfsr (
        .DSA(serial_in), .DSB(1'b1),
        .CP(noise_clk), .MR_n(1'b1),
        .Q0(lfsr_q0),.Q1(lfsr_q1),.Q2(lfsr_q2),.Q3(lfsr_q3),
        .Q4(lfsr_q4),.Q5(lfsr_q5),.Q6(lfsr_q6),.Q7(lfsr_q7)
    );

    // ========== TLC7524 衰减器 (行为级) ==========
    assign audio_out = lfsr_q7 ? (vol << 4) : 8'd0;

endmodule
