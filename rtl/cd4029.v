// cd4029.v — CD4029B 4 位可逆计数器 (Presettable Binary/Decade Up/Down Counter)
//
// CD4029B — 16-pin DIP 封装
// 同步可预置可逆计数器, 带进位前瞻
//
// 引脚映射 (DIP-16) — 据 ST HCF4029B / Fairchild CD4029BC / TI CD4029B datasheet 核对
// (三者引脚与功能一致, JEDEC B 系列 CMOS 标准):
//   Pin  1: PE   (PRESET ENABLE, 预置使能, 高有效, 异步)
//   Pin  2: Q4   (输出位 4, MSB)
//   Pin  3: JAM4 (预置输入位 4)
//   Pin  4: JAM3 (预置输入位 3)
//   Pin  5: CI   (CARRY IN, 进位输入/计数使能, 低有效: L=允许计数)
//   Pin  6: JAM2 (预置输入位 2)
//   Pin  7: CO   (CARRY OUT, 进位/借位输出, 低有效)
//   Pin  8: VSS  (地)
//   Pin  9: BD   (BINARY/DECADE, H=二进制0-15, L=十进制0-9)
//   Pin 10: UD   (UP/DOWN, H=加, L=减)
//   Pin 11: JAM1 (预置输入位 1, LSB)
//   Pin 12: Q1   (输出位 1, LSB)
//   Pin 13: Q2   (输出位 2)
//   Pin 14: Q3   (输出位 3)
//   Pin 15: CLK  (时钟, 上升沿触发)
//   Pin 16: VDD  (正电源)
//
// 功能 (据 datasheet TRUTH TABLE):
//   PE=H:        Q <= JAM (异步预置, 与时钟无关)
//   PE=L, CI=H:  保持 (计数禁止)
//   PE=L, CI=L:  CLK 上升沿 → 加/减计数 (按 UD/BD)
//   CO = L 当 (CI=L 且 计到最大值(加模式) 或 计到最小值(减模式))
//       二进制加: Q=15 时 CO=L     二进制减: Q=0 时 CO=L
//       十进制加: Q=9  时 CO=L     十进制减: Q=0 时 CO=L
//
// 级联: 低位 CO → 高位 CI (均低有效, 直接相连)
// 计满/计空信号取最高位的 CO
//
// 用途 (PSG3 v0.5): ×2 级联做 8-bit 满幅度可逆计数, 生成三角波(0→255→0 折线)

`timescale 1ns/1ps

module cd4029 (
    input  PE,    // Pin 1: 预置使能 (高有效, 异步)
    input  CI,    // Pin 5: 进位输入 (低有效: L=允许计数)
    input  BD,    // Pin 9: 二进制/十进制 (H=二进制)
    input  UD,    // Pin 10: 加/减 (H=加)
    input  CLK,   // Pin 15: 时钟 (上升沿触发)
    input  JAM1,  // Pin 11: 预置位 1 (LSB)
    input  JAM2,  // Pin 6:  预置位 2
    input  JAM3,  // Pin 4:  预置位 3
    input  JAM4,  // Pin 3:  预置位 4 (MSB)
    output Q1,    // Pin 12: 输出位 1 (LSB)
    output Q2,    // Pin 13: 输出位 2
    output Q3,    // Pin 14: 输出位 3
    output Q4,    // Pin 2:  输出位 4 (MSB)
    output CO     // Pin 7:  进位/借位输出 (低有效)
);

    reg [3:0] q_reg = 4'd0;

    wire [3:0] jam = {JAM4, JAM3, JAM2, JAM1};

    // 计数最大值 (二进制 15, 十进制 9)
    wire [3:0] max_val = BD ? 4'd15 : 4'd9;

    // 异步预置 (PE=H 立即装入), 同步计数 (CLK 上升沿)
    always @(posedge CLK or posedge PE) begin
        if (PE)
            q_reg <= jam;
        else if (!CI) begin            // CI=L 才计数
            if (UD) begin              // 加计数
                if (q_reg >= max_val)  // 计满回绕
                    q_reg <= 4'd0;
                else
                    q_reg <= q_reg + 4'd1;
            end else begin             // 减计数
                if (q_reg == 4'd0)     // 计空回绕
                    q_reg <= max_val;
                else
                    q_reg <= q_reg - 4'd1;
            end
        end
        // PE=L 且 CI=H: 保持
    end

    assign {Q4, Q3, Q2, Q1} = q_reg;

    // CO 低有效: CI=L 且计到极值 (加=最大值, 减=0)
    assign CO = (!CI && ((UD && (q_reg == max_val)) || (!UD && (q_reg == 4'd0)))) ? 1'b0 : 1'b1;

endmodule
