// psg_square_duty_v03.v — PSG2 v0.3 方波通道 + 占空比扩展 (CH0)
//
// 在 v0.2 方波基础上加分频链 + NAND 组合, 实现 4 挡占空比/八度切换。
// 分频链每级 toggle ÷2, 输出都是 50% 方波 (不同八度)。
// NAND 组合产生不同占空比 (窄脉冲音色)。
//
// 芯片清单 (方波通道共 11 片 = v0.2 已有 7 片 + 新增 4 片):
//   v0.2 已有 (7 片): HC373 + 2×HC161 + HC00(PE反相) + HC74(FF1 sync + FF2 toggle) + HC374 + TLC7524
//   新增 (4 片):
//     HC74   (U8)  — FF3(÷2→Q2) + FF4(÷2→Q3), 占空比分频链
//     HC08   (U9)  — 3 个 AND 门做占空比组合 (duty_25/125/625), 门4 闲置
//     HC153  (U10) — 4选1 占空比挡 (bit4-5 选, DB 路径)
//     HC4053 (U11) — 双 SPDT 模拟开关: 开关 X=mode(tc_hi/pe_n, bit6), 开关 Z=REF(占空比变体/Q0, bit7)
//   (HC00 只用第1路做 PE 反相, 剩余门借给噪音通道; 占空比 AND 用独立 HC08, 不借 HC00)
//
// 占空比挡 (HC374 bit4-5 控制, 频率随占空比递降):
//   00 = 50%   : Q1 (原频 f, 纯净)
//   01 = 25%   : Q1 AND Q2 (频率 f/2, 占空比 25%)
//   10 = 12.5% : Q1 AND Q2 AND Q3 (频率 f/4, 占空比 12.5%)
//   11 = 25%@f/4 : Q2 AND Q3 (频率 f/4, 25% 低八度变体; Q2/Q3 均 50%, AND 出 25%)
//
// 寄存器 (HC374):
//   bit0-3: 音量 (4 bit = 16 级, Q0-Q3 → DB4-7, 与 v0.2 完全一致)
//   bit4-5: 占空比挡 (50/25/12.5/6.25%)
//   bit6-7: 预留

`timescale 1ns/1ps

module psg_square_duty_v03 (
    input        clk,         // 64kHz 全局晶振
    input        rst_n,
    input        period_le,   // HC373 LE (写 period)
    input        A0,          // HC374 CP (写音量+占空比)
    input  [7:0] data,        // 复用总线
    output [7:0] audio_out,   // TLC7524 衰减后方波
    output       tc_out       // 噪音绑定用 (TC 输出)
);

    // ---- period 锁存 (HC373) ----
    wire [7:0] period_q;
    hc373 u_period (.OE_n(1'b0), .LE(period_le), .D(data), .Q(period_q));

    // ---- 音量+占空比锁存 (HC374) ----
    wire [7:0] ctrl_q;
    hc374 u_ctrl (.OE_n(1'b0), .CP(A0), .D(data), .Q(ctrl_q));
    wire [3:0] vol      = ctrl_q[3:0];   // 音量 (bit0-3, 与 v0.2 一致, Q0-Q3 → DB4-7)
    wire [1:0] duty_sel = ctrl_q[5:4];   // 占空比挡 (bit4-5)
    wire       mode_sel = ctrl_q[6];     // 波形模式 (bit6: 0=方波, 1=白噪)
    // ref_sel (bit7) 在 RTL 行为级不使用 — 它控制 HC4053 开关 Z (硬件层):
    //   bit7=0: HC4053 Z-COM = HC153 占空比变体 (纯净方波, RTL 此分支)
    //   bit7=1: HC4053 Z-COM = HC161 Q0 抽头 (乘法调制泛音, iverilog 复现不了, 见 design.md 5.5/5.9)
    // 此 wire 仅占位声明对应 bit7, 行为级 RTL 始终走"占空比变体"路径。
    wire       ref_sel = ctrl_q[7];

    // ---- 计数器 (HC161 x2, 复用 v0.2) ----
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

    // ---- 方波/白噪二选一 (HC4053 开关 X, 硬件层不实例化) ----
    //   mode=0: reload_src = tc_hi  → 方波
    //   mode=1: reload_src = pe_n   → 白噪 (/PE 信号, 硬件延迟产生)
    // HC4053 开关 Z 同时管 REF 切换 (占空比变体/Q0), 一片双 SPDT。
    // RTL 行为级用 mux 等效, 不实例化 HC4053 (模拟开关的音色效果仿真复现不了)。
    wire reload_src = mode_sel ? pe_n : tc_hi;

    // ---- toggle 链 (HC74 x2: FF1 sync, FF2/FF3/FF4 分频) ----
    // v0.2 的 FF1 (sync) + FF2 (toggle=Q1), 新增 FF3 (÷2=Q2), FF4 (÷2=Q3)
    reg reload_pulse = 1'b0;
    reg q1 = 1'b0;   // toggle 输出 (50%, 频率 f)
    reg q2 = 1'b0;   // Q1 的 ÷2 (50%, f/2)
    reg q3 = 1'b0;   // Q2 的 ÷2 (50%, f/4)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) reload_pulse <= 1'b0;
        else        reload_pulse <= reload_src;   // FF1: sync (源=HC153 选 tc_hi 或 pe_n)
    end
    always @(posedge reload_pulse or negedge rst_n) begin
        if (!rst_n) q1 <= 1'b0;
        else        q1 <= ~q1;               // FF2: toggle (Q1)
    end
    always @(posedge q1 or negedge rst_n) begin
        if (!rst_n) q2 <= 1'b0;
        else        q2 <= ~q2;               // FF3: ÷2 (Q2)
    end
    always @(posedge q2 or negedge rst_n) begin
        if (!rst_n) q3 <= 1'b0;
        else        q3 <= ~q3;               // FF4: ÷2 (Q3)
    end

    // ---- 占空比组合 (HC00 借剩余门做 AND/NAND) ----
    wire duty_50   = q1;                 // 50% 原频
    wire duty_25   = q1 & q2;            // 25% (频率 f/2)
    wire duty_125  = q1 & q2 & q3;       // 12.5% (频率 f/4)
    wire duty_25f4 = q2 & q3;            // 25%@f/4 低八度变体 (Q2 AND Q3)

    // ---- 占空比选通 (HC153 4选1) ----
    reg wave_sel;
    always @(*) begin
        case (duty_sel)
            2'b00: wave_sel = duty_50;
            2'b01: wave_sel = duty_25;
            2'b10: wave_sel = duty_125;
            2'b11: wave_sel = duty_25f4;
        endcase
    end

    // ---- TLC7524 衰减器 ----
    assign audio_out = wave_sel ? (vol << 4) : 8'd0;

    // ---- REF 音色选择 (bit7, HC4053 在硬件层切换, RTL 不实例化) ----
    // bit7=0: REF = toggle (纯净方波, v0.2 默认)
    // bit7=1: REF = Q0 抽头 (乘法调制泛音, 面包板实测发现)
    // HC4053 是 SPDT 模拟开关, 1 位控制 2 选 1, 保真高频谐波 (见 wiring-table.md 6.6 节)
    // RTL 不模拟真实乘法调制音色 (iverilog 复现不了物理现象, 见 design.md 5.5/5.9)

    // ---- REF 模拟开关 (CD4066, 4选1: toggle/Q0/Q1/Q2 → REF) ----
    // HC164 独热码控制 4066 的 4 路开关, 每次只导通一路。
    // RTL 只验证"切换逻辑" (独热码选对路), 不模拟真实乘法调制音色 ——
    // Q 抽头进 REF 的泛音是硬件物理现象 (HC161 输出瞬态/非理想边沿 × DAC 乘法),
    // iverilog 仿真复现不了 (见 design.md 5.5/5.9 节仿真盲区)。
    // 音量控制方案 (REF 改 Q 抽头后 DB 不再直接控音量) 待上板确认, RTL 不臆造。

endmodule
