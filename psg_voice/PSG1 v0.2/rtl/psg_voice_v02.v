// psg_voice_v02.v — 单音 PSG + 4-bit 音量 (v0.2)
//
// 相对 v0.1 的改动:
//   1. 加 HC374 (音量码锁存, D0-D3, A0 选通)
//   2. 加 TLC7524 (音量衰减器, 反向电压模式, 行为级建模)
//   3. 去 gate (HC00 第2/3路拆除), toggle_q 直接经 TLC7524 输出
//   4. 静音靠 vol=0000 (TLC7524 输出 0), 不需 gate
//
// 芯片清单 (7 片):
//   hc373 x1 — period 锁存 (复用 v0.1)
//   hc161 x2 — 计数器 (复用 v0.1)
//   hc00  x1 — PE 反相 (仅第1路, 复用 v0.1)
//   hc74  x1 — toggle 翻转 (复用 v0.1, 行为级建模等效)
//   hc374 x1 — 音量码锁存 (新增)
//   TLC7524  — 音量衰减器 (新增, 行为级模型)
//
// 接口:
//   clk       — 计数时钟 (64kHz)
//   rst_n     — 复位 (低有效)
//   period_le — period 写选通 (FT232H D4, HC373 LE)
//   A0        — 音量写选通 (FT232H D5, HC374 CP)
//   data[7:0] — 复用数据总线 (FT232H C0-C7, 写 period 全8位 / 音量低4位)
//   audio_out — 衰减后方波输出 (TLC7524 REF → 运放 → 喇叭)
//               8-bit 表示: 0-240 (vol<<4), 0=静音

`timescale 1ns/1ps

module psg_voice_v02 (
    input        clk,
    input        rst_n,
    input        period_le,   // HC373 LE (写 period)
    input        A0,          // HC374 CP (写音量, v0.1 的 gate 位置)
    input  [7:0] data,        // 复用总线
    output [7:0] audio_out    // TLC7524 衰减后方波
);

    // ---- period 锁存 (HC373) ----
    wire [7:0] period_q;
    hc373 u_period (.OE_n(1'b0), .LE(period_le), .D(data), .Q(period_q));

    // ---- 音量锁存 (HC374, 用低4位) ----
    wire [7:0] vol_q;
    hc374 u_volume (.OE_n(1'b0), .CP(A0), .D(data), .Q(vol_q));
    wire [3:0] vol = vol_q[3:0];   // 只用低 4 位 (D4-D7 接地, 锁存值高4位恒0)

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

    // ---- PE 反相 (HC00 第1路, 输入短接当反相器) ----
    hc00 u_nand (
        .A1(tc_hi),.B1(tc_hi),.Y1(pe_n),
        .A2(1'b0),.B2(1'b0),.Y2(),    // 第2路: v0.1 的 gate, 已拆除
        .A3(1'b0),.B3(1'b0),.Y3(),    // 第3路: v0.1 的 gate, 已拆除
        .A4(1'b0),.B4(1'b0),.Y4()
    );

    // ---- toggle (HCT74: 半片 sync 消毛刺 + 半片 T 翻转) ----
    // 行为级建模, 等效 HC74 双 D 触发器 (v0.1 验证过的毛刺修复)
    reg reload_pulse = 1'b0;
    reg toggle_q = 1'b0;   // 初值 0, 避免仿真 x 传播
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) reload_pulse <= 1'b0;
        else        reload_pulse <= tc_hi;   // sync 半片: D=tc_hi, clk 采样
    end
    always @(posedge reload_pulse or negedge rst_n) begin
        if (!rst_n) toggle_q <= 1'b0;
        else        toggle_q <= ~toggle_q;   // T 半片: reload 上升沿翻转
    end

    // ---- TLC7524 衰减器 (行为级, 反向电压模式) ----
    // OUT1 = toggle_q (方波参考), REF = 输出
    // 输出 = toggle_q ? (vol<<4) : 0
    //   高电平: 幅度 = vol<<4 (0-240, 对应 0-4.7V)
    //   低电平: 0
    //   vol=0 → 恒 0 (静音); vol=15 → 0/240 方波 (满音量, 94% 幅度)
    assign audio_out = toggle_q ? (vol << 4) : 8'd0;

endmodule
