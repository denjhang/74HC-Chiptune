// wt_spfm_bus.v — SPFM 总线接口 (74HC 芯片实例化)
//
// 同步链 (适配单时钟 10MHz, 参考 YM2413 IKAOPLL):
//   1. 74373 透明锁存: /CS=0 & /WR=0 时 D 跟随，异步捕获
//   2. 2级同步器 (74174 D-FF): 消除亚稳态
//   3. 上升沿检测: 产生 1-clock 宽脉冲
//
// 两路独立:
//   addr_wr: A0=0, /CS=0, /WR=0 → 地址写脉冲
//   data_wr: A0=1, /CS=0, /WR=0 → 数据写脉冲
//
// 写时序: 脉冲宽度 ≥3 个时钟 (2 拍同步 + 1 拍余量)
// 地址/数据写间隔: ≥4 个时钟 (同步器自清除时间)

`timescale 1ns/1ps

// ================================================================
// 74HC 芯片模型
// ================================================================

// 74373 — 八D透明锁存
module hc373 (
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

// 74174 — 六D触发器 (上升沿)
module hc174 (
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

// ================================================================
// 写请求同步器
//
// 2级 D-FF 同步器 + 上升沿检测
// 输入: 异步写请求 (组合逻辑: CS_n & WR_n & A0 条件)
// 输出: 同步后 1-clock 宽脉冲
//
// 硬件映射:
//   sync[0]: 74174 D-FF (posedge CLK 采样异步输入)
//   sync[1]: 74174 D-FF (消除亚稳态)
//   sync_d:  74174 D-FF (延迟 1 拍, 用于边沿检测)
//   o_OUT:   组合逻辑 AND(sync[1], ~sync_d)
// ================================================================
module write_synchronizer (
    input  wire CLK,
    input  wire RST_n,
    input  wire i_IN,
    output wire o_OUT
);

    reg [1:0] sync = 2'b00;
    reg       sync_d = 1'b0;

    always @(posedge CLK or negedge RST_n) begin
        if (!RST_n) begin
            sync   <= 2'b00;
            sync_d <= 1'b0;
        end else begin
            sync[0] <= i_IN;         // 第1级: 采样异步输入
            sync[1] <= sync[0];      // 第2级: 消除亚稳态
            sync_d  <= sync[1];      // 延迟 1 拍
        end
    end

    assign o_OUT = sync[1] & ~sync_d;

endmodule

// ================================================================
// SPFM 总线接口
// ================================================================
module wt_spfm_bus (
    input  wire        CLK,
    input  wire        RST_n,
    input  wire [7:0]  D,
    input  wire        A0,
    input  wire        CS_n,
    input  wire        WR_n,
    input  wire        RD_n,

    output wire [7:0]  reg_addr,
    output wire [7:0]  reg_data,
    output wire        addr_wr,
    output wire        data_wr
);

    // 第1级: 74373 透明锁存
    wire le = ~CS_n & ~WR_n & RST_n;

    wire [7:0] d_latched;
    hc373 u_dbus_latch (.LE(le), .D(D), .Q(d_latched));

    // 第2级: 写请求同步器
    wire addr_req = ~CS_n & ~WR_n & ~A0;
    wire data_req = ~CS_n & ~WR_n &  A0;

    write_synchronizer u_sync_addr (
        .CLK(CLK), .RST_n(RST_n), .i_IN(addr_req), .o_OUT(addr_wr)
    );

    write_synchronizer u_sync_data (
        .CLK(CLK), .RST_n(RST_n), .i_IN(data_req), .o_OUT(data_wr)
    );

    // 第3级: 地址寄存器 (addr_wr 时锁存)
    reg [7:0] reg_addr_r;
    always @(posedge CLK or negedge RST_n) begin
        if (!RST_n)
            reg_addr_r <= 8'h00;
        else if (addr_wr)
            reg_addr_r <= d_latched;
    end
    assign reg_addr = reg_addr_r;

    // 数据透传 (由下游在 data_wr 时采样)
    assign reg_data = d_latched;

endmodule
