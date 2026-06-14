// wt3_spfm_mux.v — SPFM 总线 + 157 地址 mux + 62256 参数 RAM
//
// 芯片清单 (5 IC):
//   SPFM 总线 (3): 373 (透明锁存) + 174 (同步器) + 377 (地址寄存器)
//   地址 Mux  (1): 157 (低 4 位地址选择)
//   参数 RAM  (1): 62256 (32K×8)
//
// 地址 Mux (157):
//   Select = CS_n (0=SPFM地址, 1=微码地址)
//   低 4 位通过 157 切换, 高 4 位通过 wire 切换
//
// 62256:
//   A[7:0] ← mux 输出
//   WE_n   ← data_wr_pulse_n (SPFM写时低, 微码不写)
//   OE_n   ← 微码 p1_oe_n (当前简单接法)

`timescale 1ns/1ps

module wt3_spfm_mux (
    input  wire        CLK,
    input  wire        RST_n,
    input  wire [7:0]  D,
    input  wire        A0,
    input  wire        CS_n,
    input  wire        WR_n,
    input  wire        RD_n,

    // 微码接口
    input  wire [7:0]  mc_ram_addr,
    input  wire        mc_oe_n,

    // RAM 数据输出
    output wire [7:0]  ram_do
);

    // ============================================================
    // SPFM 总线 (3 IC: 373, 174, 377)
    // ============================================================
    wire [7:0] reg_addr;
    wire [7:0] reg_data;
    wire       addr_wr_pulse_n;
    wire       data_wr_pulse_n;

    wt3_spfm_bus u_spfm (
        .CLK(CLK), .RST_n(RST_n),
        .D(D), .A0(A0),
        .CS_n(CS_n), .WR_n(WR_n), .RD_n(RD_n),
        .reg_addr(reg_addr), .reg_data(reg_data),
        .addr_wr_pulse_n(addr_wr_pulse_n),
        .data_wr_pulse_n(data_wr_pulse_n)
    );

    // ============================================================
    // 157: RAM 地址 mux (低 4 位)
    //   Select = CS_n (157 真值: Select=0→Y=A, Select=1→Y=B)
    //   CS_n=0 (SPFM 写): Select=0 → Y=A → A 接 reg_addr
    //   CS_n=1 (微码读):   Select=1 → Y=B → B 接 mc_ram_addr
    // ============================================================
    wire [7:0] ram_addr;
    wire mux_y0, mux_y1, mux_y2, mux_y3;

    hc157 u_addr_mux (
        .Select(CS_n),
        .A1(reg_addr[0]),     .B1(mc_ram_addr[0]),
        .A2(reg_addr[1]),     .B2(mc_ram_addr[1]),
        .A3(reg_addr[2]),     .B3(mc_ram_addr[2]),
        .A4(reg_addr[3]),     .B4(mc_ram_addr[3]),
        .Enable_n(1'b0),
        .Y1(mux_y0), .Y2(mux_y1),
        .Y3(mux_y2), .Y4(mux_y3)
    );

    assign ram_addr[0] = mux_y0;
    assign ram_addr[1] = mux_y1;
    assign ram_addr[2] = mux_y2;
    assign ram_addr[3] = mux_y3;
    // 高 4 位: 同样用 CS_n 选择 (wire 连线)
    assign ram_addr[7:4] = CS_n ? mc_ram_addr[7:4] : reg_addr[7:4];

    // ============================================================
    // 62256: 参数 RAM
    //   WE_n = data_wr_pulse_n (SPFM 写, 低有效, 直连)
    //   OE_n = CS_n ? mc_oe_n : 1'b1 (SPFM 操作时不读)
    // ============================================================
    wire ram_we_n = data_wr_pulse_n;
    wire ram_oe_n = CS_n ? mc_oe_n : 1'b1;

    hc62256 u_ram (
        .A0(ram_addr[0]),  .A1(ram_addr[1]),
        .A2(ram_addr[2]),  .A3(ram_addr[3]),
        .A4(ram_addr[4]),  .A5(ram_addr[5]),
        .A6(ram_addr[6]),  .A7(ram_addr[7]),
        .A8(1'b0), .A9(1'b0), .A10(1'b0), .A11(1'b0),
        .A12(1'b0), .A13(1'b0), .A14(1'b0),
        .DI(reg_data),
        .DO(ram_do),
        .CE_n(1'b0),
        .OE_n(ram_oe_n),
        .WE_n(ram_we_n)
    );

endmodule
