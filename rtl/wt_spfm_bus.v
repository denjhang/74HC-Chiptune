// wt_spfm_bus.v — SPFM 总线接口 (74HC 芯片实例化)
//
// 芯片清单 (3 IC):
//   U1: 74HC373 — D[7:0] 透明锁存
//   U2: 74HC174 — 两路同步器 (addr + data, 6 D-FF)
//   U3: 74HC377 — 地址寄存器 (8-bit)
//
// 同步链: 异步请求 → 2级 D-FF 同步 → 上升沿检测 → 1-clock 脉冲
// 写时序: 脉冲 ≥3 clocks, 地址/数据间隔 ≥4 clocks

`timescale 1ns/1ps

// ================================================================
// 74HC 芯片定义
// ================================================================

// 74HC373 — 八D透明锁存
// LE=1: Q 跟随 D (透明)
// LE=0: Q 锁存
module spfm_373 (
    input         LE,
    input  [7:0]  D,
    output [7:0]  Q
);
    reg [7:0] latch = 8'h00;
    always @(*) begin
        if (LE) latch = D;
    end
    assign Q = latch;
endmodule

// 74HC174 — 六D触发器 (上升沿, 异步清零)
// posedge CLK: Q <= D
// nCLR=0: Q <= 0 (异步)
module spfm_174 (
    input         CLK,
    input         nCLR,
    input  [5:0]  D,
    output reg [5:0] Q
);
    initial Q = 6'd0;
    always @(posedge CLK or negedge nCLR) begin
        if (!nCLR) Q <= 6'd0;
        else       Q <= D;
    end
endmodule

// 74HC377 — 八D触发器 (上升沿, 使能)
// Enable_bar=0 且 posedge Clk: Q <= D
// Enable_bar=1: Q 保持
module spfm_377 (
    input             Enable_bar,
    input      [7:0]  D,
    input             Clk,
    output reg [7:0]  Q
);
    initial Q = 8'd0;
    always @(posedge Clk) begin
        if (!Enable_bar) Q <= D;
    end
endmodule

// ================================================================
// SPFM 总线接口顶层
//
// U1: 74HC373 — 透明锁存 D[7:0]
//     LE  = ~CS_n & ~WR_n & RST_n  (CS=0,WR=0,RST=1 时透明)
//     D   = D[7:0] (总线)
//     Q   = d_latched (锁存后数据)
//
// U2: 74HC174 — 两路同步器 (6 D-FF)
//     D[0] = addr_req, D[1] = addr_sync0, D[2] = addr_sync1
//     D[3] = data_req, D[4] = data_sync0, D[5] = data_sync1
//     Q    → 2级同步 + 边沿检测
//
// U3: 74HC377 — 地址寄存器
//     Enable_bar = ~addr_wr (addr_wr=1 时使能)
//     D          = d_latched
//     Clk        = CLK
//     Q          = reg_addr
// ================================================================
module wt_spfm_bus (
    // SPFM 总线 (来自主机)
    input  wire        CLK,
    input  wire        RST_n,
    input  wire [7:0]  D,
    input  wire        A0,
    input  wire        CS_n,
    input  wire        WR_n,
    input  wire        RD_n,

    // 内部寄存器输出
    output wire [7:0]  reg_addr,
    output wire [7:0]  reg_data,
    output wire        addr_wr,
    output wire        data_wr
);

    // ============================================================
    // U1: 74HC373 — D[7:0] 透明锁存
    // ============================================================
    wire le = ~CS_n & ~WR_n & RST_n;

    wire [7:0] d_latched;
    spfm_373 U1 (
        .LE (le),
        .D  (D),
        .Q  (d_latched)
    );

    // ============================================================
    // U2: 74HC174 — 两路同步器
    //
    // addr 路径: D[0]=addr_req → Q[0]=addr_sync0
    //            D[1]=addr_sync0 → Q[1]=addr_sync1
    //            D[2]=addr_sync1 → Q[2]=addr_sync1_d (边沿检测)
    //
    // data 路径: D[3]=data_req → Q[3]=data_sync0
    //            D[4]=data_sync0 → Q[4]=data_sync1
    //            D[5]=data_sync1 → Q[5]=data_sync1_d
    // ============================================================
    wire addr_req = ~CS_n & ~WR_n & ~A0;
    wire data_req = ~CS_n & ~WR_n &  A0;

    wire [5:0] u2_d;
    wire [5:0] u2_q;

    // addr 路径反馈: Q → 下一级 D
    assign u2_d[0] = addr_req;        // 第1级: 采样异步输入
    assign u2_d[1] = u2_q[0];         // 第2级: 同步
    assign u2_d[2] = u2_q[1];         // 第3级: 延迟(边沿检测)

    // data 路径反馈
    assign u2_d[3] = data_req;
    assign u2_d[4] = u2_q[3];
    assign u2_d[5] = u2_q[4];

    spfm_174 U2 (
        .CLK  (CLK),
        .nCLR (RST_n),
        .D    (u2_d),
        .Q    (u2_q)
    );

    // 上升沿检测: sync1 & ~sync1_d = 1-clock 脉冲
    assign addr_wr = u2_q[1] & ~u2_q[2];
    assign data_wr = u2_q[4] & ~u2_q[5];

    // ============================================================
    // U3: 74HC377 — 地址寄存器
    // addr_wr=1 时 Enable_bar=0 → posedge CLK 锁存 d_latched
    // ============================================================
    wire [7:0] reg_addr_w;
    spfm_377 U3 (
        .Enable_bar (~addr_wr),
        .D          (d_latched),
        .Clk        (CLK),
        .Q          (reg_addr_w)
    );
    assign reg_addr = reg_addr_w;

    // 数据透传 (由下游在 data_wr 时采样)
    assign reg_data = d_latched;

endmodule
