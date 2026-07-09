// hc112.v — 74HC112 双 J-K 负沿触发器 (Dual J-K Negative-Edge-Triggered Flip-Flop)
//
// 74HC112 — 16-pin DIP 封装
// 2 路独立 JK 触发器, 各带 PRE (置位, 低有效) 和 CLR (清零, 低有效)
//
// 引脚映射 (DIP-16) — 据 TI SN74HC112 / Nexperia 74HC112 datasheet 核对:
//   Pin  1: 1CLK  (触发器 1 时钟, 下降沿触发)
//   Pin  2: 1K    (触发器 1 K 输入)
//   Pin  3: 1J    (触发器 1 J 输入)
//   Pin  4: 1PRE  (触发器 1 置位, 异步低有效)
//   Pin  5: 1Q    (触发器 1 正输出)
//   Pin  6: 1Q_n  (触发器 1 反相输出)
//   Pin  7: 1CLR  (触发器 1 清零, 异步低有效)
//   Pin  8: GND
//   Pin  9: 2PRE  (触发器 2 置位, 异步低有效)
//   Pin 10: 2CLR  (触发器 2 清零, 异步低有效)
//   Pin 11: 2Q    (触发器 2 正输出)
//   Pin 12: 2Q_n  (触发器 2 反相输出)
//   Pin 13: 2K    (触发器 2 K 输入)
//   Pin 14: 2J    (触发器 2 J 输入)
//   Pin 15: 2CLK  (触发器 2 时钟, 下降沿触发)
//   Pin 16: VCC
//
// 功能 (据 datasheet):
//   PRE=L, CLR=H: Q=H (异步置位, 独立于时钟)
//   PRE=H, CLR=L: Q=L (异步清零, 独立于时钟)
//   PRE=H, CLR=H: CLK 下降沿触发:
//     J=L, K=L: 保持
//     J=H, K=L: Q=H (置1)
//     J=L, K=H: Q=L (置0)
//     J=H, K=H: Q 翻转 (toggle)
//   PRE=L, CLR=L: 非法 (Q 与 Q_n 同时为 H)
//
// 与 CD4027 的区别:
//   - CD4027 上升沿触发, 112 下降沿触发
//   - CD4027 SET/RST 高有效, 112 PRE/CLR 低有效
//   - JK 真值表相同
//
// 用途 (PSG3 v0.5): 替代 CD4027 做三角波折返方向控制.
//   CD4027 不在库存, 用 74HC112 (库存有). clk 接 ~clk (下降沿采样).

`timescale 1ns/1ps

module hc112 (
    // 触发器 1
    input  CLK1_n,  // Pin 1:  时钟 (下降沿触发, RTL 接 clk 的反相)
    input  J1,      // Pin 3:  J 输入
    input  K1,      // Pin 2:  K 输入
    input  PRE1_n,  // Pin 4:  置位 (异步低有效)
    input  CLR1_n,  // Pin 7:  清零 (异步低有效)
    output Q1,      // Pin 5:  正输出
    output Q1_n,    // Pin 6:  反相输出
    // 触发器 2
    input  CLK2_n,  // Pin 15: 时钟 (下降沿触发)
    input  J2,      // Pin 14: J 输入
    input  K2,      // Pin 13: K 输入
    input  PRE2_n,  // Pin 9:  置位 (异步低有效)
    input  CLR2_n,  // Pin 10: 清零 (异步低有效)
    output Q2,      // Pin 11: 正输出
    output Q2_n     // Pin 12: 反相输出
);

    reg q1 = 1'b0;
    reg q2 = 1'b0;

    // 下降沿触发 + 异步 PRE(低)/CLR(低)
    always @(negedge CLK1_n or negedge PRE1_n or negedge CLR1_n) begin
        if (!PRE1_n)       // PRE=L 异步置位
            q1 <= 1'b1;
        else if (!CLR1_n)  // CLR=L 异步清零
            q1 <= 1'b0;
        else begin
            case ({J1, K1})
                2'b00: q1 <= q1;        // 保持
                2'b10: q1 <= 1'b1;      // 置1
                2'b01: q1 <= 1'b0;      // 置0
                2'b11: q1 <= ~q1;       // toggle
            endcase
        end
    end

    always @(negedge CLK2_n or negedge PRE2_n or negedge CLR2_n) begin
        if (!PRE2_n)
            q2 <= 1'b1;
        else if (!CLR2_n)
            q2 <= 1'b0;
        else begin
            case ({J2, K2})
                2'b00: q2 <= q2;
                2'b10: q2 <= 1'b1;
                2'b01: q2 <= 1'b0;
                2'b11: q2 <= ~q2;
            endcase
        end
    end

    assign Q1   = q1;
    assign Q1_n = ~q1;
    assign Q2   = q2;
    assign Q2_n = ~q2;

endmodule
