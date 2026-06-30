// psg_voice.v — 单音 PSG (最简方波合成器, 4 片 74HC 实例化)
//
// 设计目标: demo 用, 面包板可快速搭建, 覆盖常用音区 (A3~A5)
//
// 参考 SN76489 / AY8910 的核心机制 (STC ay8910.c):
//   count += 1; if (count >= period) { toggle; count = 0; }
//
// 最简实现: 用 hc161 自身的 TC (计满) 代替独立比较器
//   计数器从 host 预置的 period 起, 自增到 0xFF,
//   TC=1 时下个时钟同步预置回 period (重装), 同时触发 hc74 翻转出方波
//   => 有效计数长度 = 256 - period, 频率 = clk / (2*(256-period))
//
// 外部时钟不限制: 直接用 125kHz 慢时钟进 clk 端 (省掉预分频芯片)
//   125kHz + 8-bit period 覆盖: 244Hz(period=255) ~ 62.5kHz(period=0)
//   A3 220Hz 不可达(需更大), A4 440Hz(period=113), A5 880Hz(period=56)
//   => 实测覆盖约 C4~C6 区间, 足够 demo
//
// 芯片清单 (5 片 74HC, 全实例化):
//   hc373 x1 — 8-bit 透明锁存器 (host 写入 period, Q 接计数器 D 端)
//   hc161 x2 — 8-bit 计数器 (级联, TC 时从 hc373 重装 period)
//   hc00  x1 — 四 2 输入与非门 (1 路 PE 反相 + 2 路 gate 与门, 合并原 HC04+HC08)
//   hc74  x1 — 双 D 触发器 (半片同步 tc 消毛刺 + 半片 T 翻转出方波)
//
// 接口说明:
//   clk       — 计数时钟 (建议 125kHz 外部时钟, 不限制)
//   rst_n     — 复位 (低有效)
//   period_we — period 写使能 (低有效, 接 hc377 Enable)
//   period_in — host 写入的 period 值 [7:0]
//   gate      — 1=发声, 0=静音
//   wave_out  — 方波输出

`timescale 1ns/1ps

module psg_voice (
    input        clk,
    input        rst_n,
    input        period_le,    // 锁存使能 (高=透明跟随, 低=锁存保持)
    input  [7:0] period_in,
    input        gate,
    output       wave_out
);

    // -------------------------------------------------------------------
    // 1. period 锁存 (hc373 x1, 8-bit 透明锁存器)
    //    替代原 HC377 (库存无 377). HC373 是电平敏感锁存, 不接 clk:
    //      LE=1: Q 跟随 D (透明); LE=0: Q 锁存 (保持)
    //    /OE 常接 GND (永远输出). MCU 写 period: 先置 LE=1, D 放数据,
    //    再置 LE=0 锁存. 与 PSG 的 125kHz clk 完全解耦.
    // -------------------------------------------------------------------
    wire [7:0] period_q;

    hc373 u_period (
        .OE_n(1'b0),         // Pin1 /OE 接 GND, 常输出
        .LE  (period_le),    // Pin11 LE: 高透明, 低锁存
        .D   (period_in),
        .Q   (period_q)
    );

    // -------------------------------------------------------------------
    // 2. 8-bit 计数器 (hc161 x2 级联)
    //    - MR = rst_n (复位清零)
    //    - PE = ~tc_hi (计满 0xFF 时 TC=1, 下个时钟 PE=0 同步预置 period)
    //    - D 端接 period_q (重装值)
    //    - 低片 CEP/CET=1 自由计数; 高片由低片 TC 使能级联
    // -------------------------------------------------------------------
    wire tc_lo;
    wire [3:0] q_lo;
    wire [3:0] q_hi;
    wire       tc_hi;          // 8-bit 计满 (高片 TC)

    // PE 重装: HC161 PE 低有效预置, 需 count==0xFF 时 PE=0 → PE = ~tc_hi
    // ~tc_hi 由 1 片 HC04 反相器实现 (U6, 见接线表 docs/wiring-table.md)
    wire       pe_n;           // = ~tc_hi, 经 HC00 第1路反相

    hc161 u_cnt_lo (
        .MR (rst_n), .CP (clk),
        .D0 (period_q[0]), .D1 (period_q[1]),
        .D2 (period_q[2]), .D3 (period_q[3]),
        .Q0 (q_lo[0]), .Q1 (q_lo[1]), .Q2 (q_lo[2]), .Q3 (q_lo[3]),
        .CEP (1'b1), .CET (1'b1), .PE (pe_n),
        .TC  (tc_lo)
    );

    hc161 u_cnt_hi (
        .MR (rst_n), .CP (clk),
        .D0 (period_q[4]), .D1 (period_q[5]),
        .D2 (period_q[6]), .D3 (period_q[7]),
        .Q0 (q_hi[0]), .Q1 (q_hi[1]), .Q2 (q_hi[2]), .Q3 (q_hi[3]),
        .CEP (tc_lo), .CET (tc_lo), .PE (pe_n),
        .TC  (tc_hi)
    );

    // -------------------------------------------------------------------
    // 2.5 PE 反相 + gate 选通 (hc00 x1, 见第 4 节 HC00 实例)
    //     pe_n = ~tc_hi  (HC00 第1路, 输入短接当反相器)
    //     wave_out = gate & toggle_q  (HC00 第2+3路, 两级与非)
    //     HC00 实例放在 HC74 之后 (依赖 toggle_q)
    // -------------------------------------------------------------------
    wire gate_nand1;   // gate 与门第一级 (内部)
    // pe_n 由 HC00 第1路驱动, 在下方实例化

    // -------------------------------------------------------------------
    // 3. T 触发器 (hc74 x1) — 重装脉冲翻转出方波
    //    tc_hi 是 hc161 组合输出, count 经历 0xFF 时可能有毛刺,
    //    直接当 hc74 时钟会多触发。先用半个 hc74 把 reload_pulse
    //    同步一拍 (D 触发器采样), 再用其上升沿驱动 T 触发器。
    //
    //    reload_pulse = tc_hi (count==0xFF 的那个时钟周期, 持续完整周期,
    //                    无毛刺, 因为它是稳态值)
    //    实际毛刺来源是 tc 在 254->255->185 转换瞬间的组合延迟,
    //    用同步 D 触发器消除。
    // -------------------------------------------------------------------
    wire reload_pulse;          // 同步后的重装脉冲
    wire toggle_q;

    hc74 u_sync_reload (        // 半片 D 触发器: 同步 tc_hi
        .CLR1 (rst_n), .CLK1 (clk), .D1 (tc_hi), .PRE1 (1'b1),
        .Q1   (reload_pulse), .Q1_n (),
        .CLR2 (1'b1), .CLK2 (1'b0), .D2 (1'b0), .PRE2 (1'b1),
        .Q2   (), .Q2_n ()
    );

    hc74 u_toggle (             // 半片 T 触发器: reload_pulse 上升沿翻转
        .CLR1 (rst_n), .CLK1 (reload_pulse), .D1 (~toggle_q), .PRE1 (1'b1),
        .Q1   (toggle_q), .Q1_n (),
        .CLR2 (1'b1), .CLK2 (1'b0), .D2 (1'b0), .PRE2 (1'b1),
        .Q2   (), .Q2_n ()
    );

    // -------------------------------------------------------------------
    // 4. HC00 (四 2 输入与非门) — 一片同时做 PE 反相 + gate 与门
    //     第1路: pe_n = ~(tc_hi & tc_hi) = ~tc_hi   (输入短接当反相器)
    //     第2路: gate_nand1 = ~(gate & toggle_q)
    //     第3路: wave_out = ~(gate_nand1 & gate_nand1) = gate & toggle_q
    //     第4路: 闲置
    //     (合并了原 HC04 反相器 + HC08 与门, 省一片)
    // -------------------------------------------------------------------
    hc00 u_nand (
        .A1 (tc_hi),      .B1 (tc_hi),        .Y1 (pe_n),         // PE 反相
        .A2 (gate),       .B2 (toggle_q),     .Y2 (gate_nand1),   // gate 与门第一级
        .A3 (gate_nand1), .B3 (gate_nand1),   .Y3 (wave_out),     // gate 与门第二级(正与)
        .A4 (1'b0),       .B4 (1'b0),         .Y4 ()              // 闲置
    );

endmodule
