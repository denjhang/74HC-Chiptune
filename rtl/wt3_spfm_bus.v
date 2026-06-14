// wt3_spfm_bus.v — SPFM 总线接口 (3 IC: 373, 174, 377)
//
// YM2413 风格双步写协议:
//   写地址: A0=0, CS_n=0, WR_n=0 → addr_wr 脉冲
//   写数据: A0=1, CS_n=0, WR_n=0 → data_wr 脉冲
//   间隙:   CS_n=1 或 WR_n=1
//
// 架构:
//   U1: 74HC373 — D[7:0] 透明锁存
//       LE = ~(CS_n | WR_n)  (CS=0 & WR=0 时透明)
//   U2: 74HC174 — 同步器 (addr_wr 用 4 个 FF, data_wr 用 2 个 FF)
//       addr_wr: R1,R2 两级同步 + 上升沿检测(R3) 产生 1 clk 脉冲
//       data_wr: R1,R2 两级同步 (电平输出, 外部用下降沿检测)
//   U3: 74HC377 — 地址寄存器
//       Enable_bar = addr_wr_pulse (上升沿脉冲), posedge CLK 锁存
//
// 同步链:
//   主机信号 → 异步锁存(373) → 2级同步(174) → 上升沿检测 → 1 clk 脉冲
//
// 译码: 组合逻辑 (AND 门, 可用 7408 实现)
//   write_active = ~CS_n & ~WR_n & RST_n  (高有效: 写操作进行中)
//   addr_wr_comb = write_active & ~A0     (写地址时为高)
//   data_wr_comb = write_active & A0      (写数据时为高)

`timescale 1ns/1ps

module wt3_spfm_bus (
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
    output wire        addr_wr_pulse,   // posedge CLK 1 clk 高脉冲 (写地址)
    output wire        data_wr_pulse    // posedge CLK 1 clk 高脉冲 (写数据)
);

    // ============================================================
    // U1: 74HC373 — D[7:0] 透明锁存
    //   LE=1 (CS=0 & WR=0): Q 跟随 D
    //   LE=0: Q 锁存
    // ============================================================
    wire le = ~(CS_n | WR_n);

    reg [7:0] d_latch = 8'h00;
    always @(*) begin
        if (le)
            d_latch = D;
    end

    // ============================================================
    // 译码: 组合逻辑 (AND 门)
    //   write_active: 高有效, CS=0 & WR=0 & RST=1 时为高
    // ============================================================
    wire write_active = ~CS_n & ~WR_n & RST_n;
    wire addr_wr_comb = write_active & ~A0;
    wire data_wr_comb = write_active & A0;

    // ============================================================
    // U2: 74HC174 — 同步器 (6 个 FF, 用 4+2)
    //
    // addr_wr 通道: 3 级 FF + 边沿检测
    //   R1: 第一级同步 (消除亚稳态)
    //   R2: 第二级同步 (稳定信号)
    //   上升沿检测: R2=1 & R1=0 → addr_wr_pulse=1 (1 clk 宽)
    //   实际用 R2 上升沿: 在 R2 刚变高的那个时钟周期产生脉冲
    //   但 R2 采样的是 addr_wr_comb, 如果 comb 已经持续多周期高,
    //   R1 也已经高, 则 R2 上升沿只发生在第一拍
    //
    // data_wr 通道: 2 级 FF + 边沿检测
    //   R1: 第一级同步
    //   R2: 第二级同步
    //   上升沿检测: R2=1 & R1_prev=0 (R1的前一拍值)
    //   由于 R2 <= R1, 当 R1 从 0→1 时, 下一个时钟 R2 也从 0→1
    //   所以检测 R2 上升沿等效于检测 R1 的前一个时钟周期
    //   简化: 用 ~R2_delayed & R2 作为脉冲 (R2 的上升沿)
    // ============================================================

    // addr_wr 通道
    reg addr_wr_r1 = 1'b0;
    reg addr_wr_r2 = 1'b0;
    reg addr_wr_r3 = 1'b0;  // 延迟一拍, 用于上升沿检测

    // data_wr 通道
    reg data_wr_r1 = 1'b0;
    reg data_wr_r2 = 1'b0;

    always @(posedge CLK or negedge RST_n) begin
        if (!RST_n) begin
            addr_wr_r1 <= 1'b0;
            addr_wr_r2 <= 1'b0;
            addr_wr_r3 <= 1'b0;
            data_wr_r1 <= 1'b0;
            data_wr_r2 <= 1'b0;
        end else begin
            addr_wr_r1 <= addr_wr_comb;
            addr_wr_r2 <= addr_wr_r1;
            addr_wr_r3 <= addr_wr_r2;
            data_wr_r1 <= data_wr_comb;
            data_wr_r2 <= data_wr_r1;
        end
    end

    // 上升沿检测: 当 R2 从 0→1 时, r3 还是 0 (上一拍的 R2 值)
    // 所以脉冲 = R2 & ~R3
    assign addr_wr_pulse = addr_wr_r2 & ~addr_wr_r3;
    assign data_wr_pulse = data_wr_r2 & ~data_wr_r1;

    // ============================================================
    // U3: 74HC377 — 地址寄存器
    //   posedge CLK, Enable_bar=0 时锁存
    //   addr_wr_pulse=1 期间 Enable_bar=0
    // ============================================================
    hc377 u_addr_reg (
        .Enable_bar(~addr_wr_pulse),
        .D(d_latch),
        .Clk(CLK),
        .Q(reg_addr)
    );

    // reg_data: 直接用 373 锁存值
    assign reg_data = d_latch;

endmodule
