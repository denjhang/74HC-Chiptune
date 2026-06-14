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
//   U2: 74HC174 — 同步器 (addr_wr 3级 + data_wr 2级)
//       输出延迟后的同步电平 (非边沿检测)
//   U3: 74HC377 — 地址寄存器
//       Enable_bar = addr_wr_pulse_n (同步后低有效)
//
// 同步链:
//   主机信号 → 异步锁存(373) → 组合译码 → 2级同步(174) → 延迟输出
//
// 输出极性: 全部低有效 (与 CS_n/WR_n/RD_n/RST_n 一致)
//   addr_wr_pulse_n: 写地址脉冲 (低有效, 直连 377 Enable_bar)
//   data_wr_pulse_n: 写数据脉冲 (低有效, 直连 62256 WE_n)
//
// 译码: 组合逻辑 (PCB 飞线 AND + INV)
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

    // 内部寄存器输出 (低有效)
    output wire [7:0]  reg_addr,
    output wire [7:0]  reg_data,
    output wire        addr_wr_pulse_n,
    output wire        data_wr_pulse_n
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
    // 译码: 组合逻辑 (PCB 飞线 AND + INV)
    // ============================================================
    wire write_active = ~CS_n & ~WR_n & RST_n;
    wire addr_wr_comb = write_active & ~A0;
    wire data_wr_comb = write_active & A0;

    // ============================================================
    // U2: 74HC174 — 同步器 (6 个 FF, 用 3+2+1)
    //
    // 同步链: comb → R1 → R2 → R3
    //   addr_wr_pulse_n = ~R3: write_active 变高后第 3 个 clk 变低
    //     377 在该 posedge 看到 Enable_bar=0, 锁存 d_latch (已稳定)
    //   data_wr_pulse_n = ~R2: write_active 变高后第 2 个 clk 变低
    //     62256 WE_n 变低, 在下一个 posge 前写入完成
    //
    // 脉冲宽度 ≈ write_active 持续时间 - 同步延迟
    // CPU 写脉冲 ≥3 clk 即可保证至少 1 clk 有效脉冲
    // ============================================================

    reg addr_wr_r1 = 1'b0;
    reg addr_wr_r2 = 1'b0;
    reg addr_wr_r3 = 1'b0;

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
            #1 addr_wr_r1 <= addr_wr_comb;  // 1ns propagation (真实 ~15ns)
            #1 addr_wr_r2 <= addr_wr_r1;
            #1 addr_wr_r3 <= addr_wr_r2;
            #1 data_wr_r1 <= data_wr_comb;
            #1 data_wr_r2 <= data_wr_r1;
        end
    end

    // 同步后取反: 延迟足够的 clk 后变低, 下游在 posedge 能采样到
    assign addr_wr_pulse_n = ~addr_wr_r3;
    assign data_wr_pulse_n = ~data_wr_r2;

    // ============================================================
    // U3: 74HC377 — 地址寄存器
    //   posedge CLK, Enable_bar=0 时锁存
    //   addr_wr_pulse_n=0 时 Enable_bar=0 (直连, 无隐藏反相)
    //   d_latch 在此之前已由 373 锁存 (CS/WR 恢复后 LE=0)
    // ============================================================
    hc377 u_addr_reg (
        .Enable_bar(addr_wr_pulse_n),
        .D(d_latch),
        .Clk(CLK),
        .Q(reg_addr)
    );

    // reg_data: 直接用 373 锁存值
    assign reg_data = d_latch;

endmodule
