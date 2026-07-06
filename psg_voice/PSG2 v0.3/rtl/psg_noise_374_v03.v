// psg_noise_374_v03.v — PSG2 v0.3 LFSR 白噪音 (HC374 版本)
//
// 用 74HC374 八 D 触发器替代 HC164 做 LFSR 主体。
// 原因: HC164 国产芯片质量不稳定 + 上电全 0 死锁。
// HC374 是边沿 D 触发器, D 输入独立, 上电启动逻辑可强制注入非 0 种子。
//
// 芯片清单 (噪音核心, 不含分频/选通/DAC):
//   HC374 x1 — 8 位 LFSR 主体 (D 触发器阵列)
//   HC86  x1 — 门1-2: XOR 反馈 (Q7⊕Q5⊕Q4⊕Q3, 周期 255)
//              门3-4: 启动逻辑 (上电强制 D0=1 一小段时间)
//
// LFSR 结构 (Galois/XOR 反馈, max-length 周期 255):
//   Q0 ← D0 = feedback = Q7⊕Q5⊕Q4⊕Q3 (或启动逻辑强制 1)
//   Q1 ← D1 = Q0 (移位)
//   Q2 ← D2 = Q1
//   ...
//   Q7 ← D7 = Q6
//
// 启动逻辑 (上电防死锁):
//   HC374 上电 Q 全 0 (RTL reg 初值), XOR 反馈 = 0 → 死锁。
//   上电后启动计数器填满 LFSR (强制 D0=1, 持续 16 个 CP),
//   16 拍后 LFSR ≠ 0, 释放反馈接管。max-length 性质保证此后永不归零。
//
// 寄存器 (HC374 控制寄存器, 与 HC164 版一致):
//   bit0-3: 音量 (Q0-Q3 → DB4-7)
//   bit4-5: 频率挡 (00=÷2 / 01=÷4 / 10=÷8 / 11=÷16)
//   bit6:   绑定开关 (0=独立 / 1=绑定 square_tc)
//   bit7:   预留

`timescale 1ns/1ps

module psg_noise_374_v03 (
    input        clk,         // 64kHz 全局晶振
    input        A1,          // HC374 CP (写噪音控制寄存器, FT232H D7)
    input  [7:0] data,        // 复用数据总线
    input        square_tc,   // 方波通道 TC (绑定模式时钟源)
    output [7:0] audio_out    // TLC7524 衰减后噪音
);

    // ========== 控制寄存器 (HC374) ==========
    wire [7:0] ctrl_q;
    hc374 u_ctrl (.OE_n(1'b0), .CP(A1), .D(data), .Q(ctrl_q));

    wire [1:0] freq_sel = ctrl_q[5:4];
    wire       bind_sw  = ctrl_q[6];
    wire [3:0] vol      = ctrl_q[3:0];

    // ========== 独立分频器 (HC161, 自由计数) ==========
    wire [3:0] div_q;
    wire       div_tc;
    hc161 u_div161 (
        .MR(1'b1), .CP(clk),
        .D0(1'b0),.D1(1'b0),.D2(1'b0),.D3(1'b0),
        .Q0(div_q[0]),.Q1(div_q[1]),.Q2(div_q[2]),.Q3(div_q[3]),
        .CEP(1'b1),.CET(1'b1),.PE(1'b1),.TC(div_tc)
    );

    // ========== 频率选通 (HC153 上半部 4 选 1) ==========
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

    // ========== 绑定 2 选 1 (行为级, 硬件用独立 HC00) ==========
    wire noise_clk = bind_sw ? square_tc : ind_clk;

    // ========== LFSR 主体 (HC374 八 D 触发器) ==========
    // Q: 当前 LFSR 状态 (8 位)
    // D: 下一个状态
    //   D[0] = feedback (XOR) 或启动逻辑强制 1
    //   D[i] = Q[i-1] (移位)
    reg [7:0] lfsr_q = 8'h00;
    reg [7:0] lfsr_d;
    reg [4:0] startup_cnt = 5'd0;   // 上电启动计数器 (0-15 填充, 16+ 释放)
    wire      startup_active = (startup_cnt < 5'd16);

    // XOR 反馈 (max-length 8 位, taps Q7⊕Q5⊕Q4⊕Q3, 周期 255)
    // 硬件: HC86 门1 = Q7⊕Q5, 门2 = Q4⊕Q3, 门3 = (Q7⊕Q5)⊕(Q4⊕Q3)
    wire xor_a = lfsr_q[7] ^ lfsr_q[5];
    wire xor_b = lfsr_q[4] ^ lfsr_q[3];
    wire feedback = xor_a ^ xor_b;

    // 启动逻辑: 上电后 16 个 CP 强制 D[0]=1 (填满 LFSR), 之后释放
    // 硬件: HC86 门4 当启动 MUX (startup_active ? 1 : feedback)
    // 启动计数器在 noise_clk 上升沿递增, 到 16 停止
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

    // ========== TLC7524 衰减器 (行为级) ==========
    // REF = Q7 (1-bit 噪音波形), DB4-7 = 音量
    assign audio_out = lfsr_q[7] ? (vol << 4) : 8'd0;

endmodule
