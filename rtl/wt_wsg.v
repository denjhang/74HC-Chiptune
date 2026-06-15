// wt_wsg.v — WSG 合成器 (行为对齐文档Verilog)
//
// 基于 Pac-Man技术文档 Verilog 实现
// 芯片: 157, 158, 86, 283, 174, 273, 189×2, 27C256×2, 4066
//
// 数据通路:
//   189(acc) 反相输出 → 283 A端
//   189(freq) 反相输出 → 283 B端
//   283 加法结果 → 174 锁存
//   174 输出 → 158 B端 → 反相写回189
//   174 Q[4:0] + acc_do[2:0] → 1M ROM 地址
//   1M ROM 数据 + acc_do → 273 输出锁存
//
// 3M ROM 控制 (地址 0x40 + hcnt):
//   DQ0 = 174 CLK (上升沿锁存)
//   DQ1 = freq RAM nWE (低电平写)
//   DQ2 = 273 锁存控制
//   DQ3 = 174 nCLR (低电平清零)

`timescale 1ns/1ps

// ================================================================
// TTL 芯片实例
// ================================================================

// 74LS189 — 16×4 RAM (反相输出)
module ttl_74189 (
    input         A, B, C, D,
    input  [3:0]  DI,
    output [3:0]  DO,
    input         nCS, nWE
);
    reg [3:0] mem [0:15];
    wire [3:0] addr = {D, C, B, A};
    assign DO = (!nCS && nWE) ? ~mem[addr] : 4'bzzzz;
    always @(negedge nWE) begin
        if (!nCS) mem[addr] <= DI;
    end
endmodule

// 74157 — 四2选1 MUX
module ttl_74157 (
    input         nSEL,
    input  [3:0]  A, B,
    input         nE,
    output [3:0]  Y
);
    assign Y = nE ? 4'bzzzz : (nSEL ? B : A);
endmodule

// 74158 — 四2选1 MUX (反相输出)
module ttl_74158 (
    input         nSEL,
    input  [3:0]  A, B,
    input         nE,
    output [3:0]  Y
);
    assign Y = nE ? 4'bzzzz : (nSEL ? ~B : ~A);
endmodule

// 7486 — 四2输入异或门
module ttl_7486 (
    input  [3:0]  A, B,
    output [3:0]  Y
);
    assign Y = A ^ B;
endmodule

// 74283 — 4-bit 全加器
module ttl_74283 (
    input         C0,
    input  [3:0]  A, B,
    output [3:0]  S,
    output        C4
);
    wire [4:0] sum = {1'b0, A} + {1'b0, B} + {4'b0, C0};
    assign S  = sum[3:0];
    assign C4 = sum[4];
endmodule

// 74174 — 六D触发器
module ttl_74174 (
    input         CLK, nCLR,
    input  [5:0]  D,
    output reg [5:0] Q
);
    initial Q = 6'd0;
    always @(posedge CLK or negedge nCLR) begin
        if (!nCLR) Q <= 6'd0;
        else Q <= D;
    end
endmodule

// 74273 — 八D触发器
module ttl_74273 (
    input         CLK, nCLR,
    input  [7:0]  D,
    output reg [7:0] Q
);
    always @(posedge CLK or negedge nCLR) begin
        if (!nCLR) Q <= 8'd0;
        else Q <= D;
    end
endmodule

// 27C256 — 32K×8 ROM
module rom_27c256 #(
    parameter INIT_FILE = ""
) (
    input              nCE, nOE,
    input  [14:0]      ADDR,
    output     [7:0]   DQ
);
    reg [7:0] mem [0:32767];
    integer i;
    initial begin
        for (i = 0; i < 32768; i = i + 1) mem[i] = 8'h00;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end
    assign DQ = (!nCE && !nOE) ? mem[ADDR] : 8'bzzzzzzzz;
endmodule

// ================================================================
// 顶层 WSG
// ================================================================
module wt_wsg (
    input  wire        clk,
    input  wire [3:0]  cpu_ab,
    input  wire [3:0]  cpu_db,
    input  wire        cpu_wr0_n,
    input  wire        cpu_wr1_n,
    input  wire        sound_on,
    input  wire        gm_n,
    input  wire [5:0]  hcnt,
    input  wire        rst_n,
    output wire        sound_out
);

wire h32 = hcnt[5], h16 = hcnt[4], h8 = hcnt[3];
wire h4  = hcnt[2], h2  = hcnt[1], h1  = hcnt[0];

// ================================================================
// sel = 2H (86 XOR GND)
// sel=0: 157/158 选A端 (CPU)
// sel=1: 157/158 选B端 (合成器)
// ================================================================
wire sel = h2;

// ================================================================
// U4: 157 — 地址 MUX
// A = CPU地址, B = hcnt高位
// sel=0(h2=0): CPU地址 → 189
// sel=1(h2=1): hcnt高位 → 189
// ================================================================
wire [3:0] addr_y;
ttl_74157 U4 (.nSEL(sel), .A(cpu_ab), .B({h32, h16, h8, h4}),
               .nE(1'b0), .Y(addr_y));

// ================================================================
// U3: 27C256 — 3M microcode ROM
// A6 = cpu_wr0_n: 正常=1(地址0x40+), CPU写=0(地址0x00+)
// /CE = gm_n, /OE = GND
// ================================================================
wire [14:0] u3_addr = {8'b0, cpu_wr0_n, hcnt};
wire [7:0]  u3_dq;
rom_27c256 #(.INIT_FILE("D:/working/vscode-projects/74HC-Chiptune/rom/rom3m.hex"))
    U3 (.nCE(gm_n), .nOE(1'b0), .ADDR(u3_addr), .DQ(u3_dq));

wire ctrl_clk  = u3_dq[0]; // DQ0 → 174 CLK
wire ctrl_nwe  = u3_dq[1]; // DQ1 → freq RAM nWE
wire ctrl_dq2  = u3_dq[2]; // DQ2 → 273 控制
wire ctrl_clr  = u3_dq[3]; // DQ3 → 174 nCLR

// ================================================================
// 前向声明
// ================================================================
wire [3:0] acc_do;   // acc RAM 反相输出
wire [3:0] freq_do;  // freq RAM 反相输出
wire [3:0] u8_s;     // 283 加法结果
wire        u8_c4;   // 283 进位输出
wire [5:0]  u9_q;    // 174 锁存输出
wire [7:0]  u10_dq;  // 1M ROM 数据输出
wire [7:0]  u11_q;   // 273 输出

// ================================================================
// U8: 283 — 4-bit 加法器
// A = acc_do (反相), B = freq_do (反相)
// C0 = u9_q[5] (进位反馈 = 上次C4锁存值)
// sum_1K = acc_do + freq_do + C0 (6-bit, bit5总是0)
// 整个加法在反相域运行, 两级反相抵消
// ================================================================
ttl_74283 U8 (.C0(u9_q[5]), .A(acc_do), .B(freq_do),
               .S(u8_s), .C4(u8_c4));

// ================================================================
// U9: 174 — 六D触发器
// 文档: sum_d_1L <= {sum_1K, sum_d_1L[3]}
//   D[5]   = C4 (283进位)
//   D[4:1] = S[3:0] (283加法结果)
//   D[0]   = old_Q[3] (上次S[2]反馈)
// CLK = ctrl_clk (3M DQ0), nCLR = ctrl_clr (3M DQ3)
// ================================================================
wire [5:0] u9_d = {u8_c4, u8_s, u9_q[3]};
ttl_74174 U9 (.CLK(ctrl_clk), .nCLR(ctrl_clr), .D(u9_d), .Q(u9_q));

// ================================================================
// U5: 158 — 数据 MUX (反相输出)
// A = CPU数据 (sel=0时选中)
// B = 174输出 (sel=1时选中, 反相输出)
// 反相输出抵消189的反相输入
// ================================================================
// 158 B端: 174的Q[4:1] (文档: B = 174回写数据)
// sel=1(h2=1)时, B端被选中, 158反相输出 → 189 DI
// 174输出是反相域, 158再反相一次 = 正常值 → 写入189
// 189读出反相 → 整个环路在反相域运行
wire [3:0] data_b = u9_q[4:1];
wire [3:0] data_y;
ttl_74158 U5 (.nSEL(sel), .A(cpu_db), .B(data_b),
               .nE(1'b0), .Y(data_y));

// ================================================================
// U6: 189 — acc RAM
// 地址 = addr_y (157输出)
// nWE = cpu_wr1_n (CPU写)
// 输出反相 → 283 A端 + 273 高4位
// ================================================================
ttl_74189 U6 (
    .A(addr_y[0]), .B(addr_y[1]), .C(addr_y[2]), .D(addr_y[3]),
    .DI(data_y), .DO(acc_do),
    .nCS(1'b0), .nWE(cpu_wr1_n)
);

// ================================================================
// U7: 189 — freq RAM
// nWE = ctrl_nwe (3M DQ1控制, 合成器回写)
// 输出反相 → 283 B端 + 1M ROM地址
// ================================================================
ttl_74189 U7 (
    .A(addr_y[0]), .B(addr_y[1]), .C(addr_y[2]), .D(addr_y[3]),
    .DI(data_y), .DO(freq_do),
    .nCS(1'b0), .nWE(ctrl_nwe)
);

// ================================================================
// U10: 27C256 — 1M 波形 ROM
// 地址: rom1m_addr[7:5] = acc_do[2:0] (波形选择)
//       rom1m_addr[4:0] = u9_q[4:0] (累加器高5位)
// 注意: acc_do是反相输出, 但波形选择只需要3位索引
// /CE=GND, /OE=GND (始终输出)
// ================================================================
wire [7:0] u10_addr = {3'b0, acc_do[2:0], u9_q[4:0]};
rom_27c256 #(.INIT_FILE("D:/working/vscode-projects/74HC-Chiptune/rom/rom1m.hex"))
    U10 (.nCE(1'b0), .nOE(1'b0), .ADDR({7'b0, u10_addr}), .DQ(u10_dq));

// ================================================================
// U11: 273 — 输出锁存
// D = {acc_do[3:0], u10_dq[3:0]} (8-bit)
// 高4位 = acc (音量/累加器), 低4位 = 波形数据
// CLK = sound_on, nCLR = rst_n
// ================================================================
wire [7:0] u11_d = {acc_do, u10_dq[3:0]};
ttl_74273 U11 (.CLK(sound_on), .nCLR(rst_n), .D(u11_d), .Q(u11_q));

// ================================================================
// DAC 输出 (简化)
// 273 低4位 = 波形采样值 (经4066音量控制)
// 实际硬件: 4066由273高4位控制, 波形数据通过电阻网络DAC
// ================================================================
assign sound_out = |u11_q[3:0];

endmodule
