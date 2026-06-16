`timescale 1ns/1ps

// wsg3_core.v — WSG3 重新设计 (用 acc RAM 直接作为相位)
//
// 关键改进：相位 = acc[0] 的低 5 位 (直接从 RAM 读取)
// 不再依赖 carry_chain 的滑动窗算法

module wsg3_core (
    input  wire        SPFM_CLK,
    input  wire        SPFM_RST_n,
    input  wire [7:0]  SPFM_D,
    input  wire        SPFM_A0,
    input  wire        SPFM_CS_n,
    input  wire        SPFM_WR_n,
    input  wire        SPFM_RD_n,

    output wire [7:0]  dac_out
);

    // SPFM 总线接口
    wire [7:0] reg_addr;
    wire [7:0] reg_data;
    wire       addr_wr_pulse_n;
    wire       data_wr_pulse_n;

    wt3_spfm_bus u_spfm (
        .CLK(SPFM_CLK),
        .RST_n(SPFM_RST_n),
        .D(SPFM_D),
        .A0(SPFM_A0),
        .CS_n(SPFM_CS_n),
        .WR_n(SPFM_WR_n),
        .RD_n(SPFM_RD_n),
        .reg_addr(reg_addr),
        .reg_data(reg_data),
        .addr_wr_pulse_n(addr_wr_pulse_n),
        .data_wr_pulse_n(data_wr_pulse_n)
    );

    // HCNT 6-bit 计数器
    reg [5:0] hcnt_r;
    always @(posedge SPFM_CLK or negedge SPFM_RST_n) begin
        if (!SPFM_RST_n)
            hcnt_r <= 6'b0;
        else
            hcnt_r <= hcnt_r + 1'b1;
    end

    wire [3:0] tdm_step = hcnt_r[5:2];
    wire [1:0] sub_cyc  = hcnt_r[1:0];

    // 微码 ROM
    wire [7:0] rom3m_data;
    hc39sf040 #(.ADDR_WIDTH(19), .DATA_WIDTH(8), .INIT_FILE("rom/wsg3_prom3m.hex"))
        u_u3 (
        .A0(sub_cyc[0]), .A1(sub_cyc[1]),
        .A2(tdm_step[0]), .A3(tdm_step[1]), .A4(tdm_step[2]), .A5(tdm_step[3]),
        .A6(1'b0), .A7(1'b0),
        .A8(1'b0), .A9(1'b0), .A10(1'b0), .A11(1'b0),
        .A12(1'b0), .A13(1'b0), .A14(1'b0), .A15(1'b0),
        .A16(1'b0), .A17(1'b0), .A18(1'b0),
        .DQ(rom3m_data),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // 控制位
    wire rom3m_clr_n    = rom3m_data[3];
    wire rom3m_acc_we_n = rom3m_data[2];
    wire cp273          = rom3m_data[1] & SPFM_RST_n & ~((~SPFM_CS_n) & (~SPFM_WR_n));
    wire clk174         = rom3m_data[0] & SPFM_RST_n & ~((~SPFM_CS_n) & (~SPFM_WR_n));

    wire clr174_n = (~SPFM_RST_n) ? 1'b0 :
                    ((~SPFM_CS_n) & (~SPFM_WR_n)) ? 1'b1 :
                    rom3m_clr_n;

    // RAM 地址
    wire [3:0] ram_addr;

    hc157 u_u4 (
        .Select(~((~SPFM_CS_n) & (~SPFM_WR_n))),
        .A1(reg_addr[0]), .B1(tdm_step[0]), .Y1(ram_addr[0]),
        .A2(reg_addr[1]), .B2(tdm_step[1]), .Y2(ram_addr[1]),
        .A3(reg_addr[2]), .B3(tdm_step[2]), .Y3(ram_addr[2]),
        .A4(reg_addr[3]), .B4(tdm_step[3]), .Y4(ram_addr[3]),
        .Enable_n(1'b0)
    );

    // RAM 数据输入 (反相)
    wire [3:0] ram_din_inv;

    hc158 u_u5 (
        .Select(~((~SPFM_CS_n) & (~SPFM_WR_n))),
        .A1(reg_data[0]), .B1(adder_s[0]), .Y1(ram_din_inv[0]),
        .A2(reg_data[1]), .B2(adder_s[1]), .Y2(ram_din_inv[1]),
        .A3(reg_data[2]), .B3(adder_s[2]), .Y3(ram_din_inv[2]),
        .A4(reg_data[3]), .B4(adder_s[3]), .Y4(ram_din_inv[3])
    );

    // U6: acc RAM
    wire [3:0] u6_do_inv;
    wire [3:0] acc_dout = ~u6_do_inv;
    wire       u6_cs_n  = 1'b0;

    wire u6_we_n = (~SPFM_RST_n) ? 1'b1 :
                  ((~SPFM_CS_n) & (~SPFM_WR_n) && reg_addr[4]) ? 1'b1 :
                  ((~SPFM_CS_n) & (~SPFM_WR_n)) ? data_wr_pulse_n :
                  rom3m_acc_we_n;

    ls189 u_u6 (
        .A0(ram_addr[0]), .A1(ram_addr[1]), .A2(ram_addr[2]), .A3(ram_addr[3]),
        .WE_n(u6_we_n),
        .CS_n(u6_cs_n),
        .D0(ram_din_inv[0]), .D1(ram_din_inv[1]),
        .D2(ram_din_inv[2]), .D3(ram_din_inv[3]),
        .RST_n(SPFM_RST_n),
        .O0(u6_do_inv[0]), .O1(u6_do_inv[1]),
        .O2(u6_do_inv[2]), .O3(u6_do_inv[3])
    );

    // U7: freq RAM
    wire [3:0] u7_do_inv;
    wire [3:0] freq_dout = ~u7_do_inv;
    wire       u7_cs_n   = 1'b0;

    wire u7_we_n = (~SPFM_RST_n) ? 1'b1 :
                   ((~SPFM_CS_n) & (~SPFM_WR_n) && reg_addr[4]) ? data_wr_pulse_n :
                                                  1'b1;

    ls189 u_u7 (
        .A0(ram_addr[0]), .A1(ram_addr[1]), .A2(ram_addr[2]), .A3(ram_addr[3]),
        .WE_n(u7_we_n),
        .CS_n(u7_cs_n),
        .D0(ram_din_inv[0]), .D1(ram_din_inv[1]),
        .D2(ram_din_inv[2]), .D3(ram_din_inv[3]),
        .RST_n(SPFM_RST_n),
        .O0(u7_do_inv[0]), .O1(u7_do_inv[1]),
        .O2(u7_do_inv[2]), .O3(u7_do_inv[3])
    );

    // 前向声明
    wire [5:0] carry_chain;
    wire [3:0] adder_s;
    wire       adder_c4;

    // U8: 加法器
    hc283 u_u8 (
        .A(acc_dout),
        .B(freq_dout),
        .C0(carry_chain[5]),
        .S(adder_s),
        .C4(adder_c4)
    );

    // U9: carry chain
    hc174 u_u9 (
        .CLR(clr174_n),
        .D1(carry_chain[3]),
        .D2(adder_s[0]),
        .D3(adder_s[1]),
        .D4(adder_s[2]),
        .D5(adder_s[3]),
        .D6(adder_c4),
        .CLK(clk174),
        .Q1(carry_chain[0]),
        .Q2(carry_chain[1]),
        .Q3(carry_chain[2]),
        .Q4(carry_chain[3]),
        .Q5(carry_chain[4]),
        .Q6(carry_chain[5])
    );

    // ============================================================
    // 关键改进：相位直接用 acc_dout (acc[0] 的低 5 位)
    // 不再使用 carry_chain 滑动窗
    // ============================================================
    wire [2:0] wave_sel  = acc_dout[2:0];
    wire [4:0] phase_sel  = {acc_dout[2], acc_dout[1], acc_dout[0], 2'b00};  // 只用低 3 位

    hc39sf040 #(.ADDR_WIDTH(19), .DATA_WIDTH(8), .INIT_FILE("rom/wsg3_prom1m.hex"))
        u_u10 (
        .A0(wave_sel[0]), .A1(wave_sel[1]), .A2(wave_sel[2]),
        .A3(phase_sel[0]), .A4(phase_sel[1]), .A5(phase_sel[2]),
        .A6(phase_sel[3]), .A7(phase_sel[4]),
        .A8(1'b0), .A9(1'b0), .A10(1'b0), .A11(1'b0),
        .A12(1'b0), .A13(1'b0), .A14(1'b0), .A15(1'b0),
        .A16(1'b0), .A17(1'b0), .A18(1'b0),
        .DQ(rom1m_data),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    wire [3:0] wave_sample = rom1m_data[3:0];

    // U11: 输出寄存器
    wire [7:0] out_d = {freq_dout, wave_sample};
    wire [7:0] u11_q;

    hc273 #(.WIDTH(8)) u_u11 (
        .MR_n(SPFM_RST_n),
        .CP(cp273),
        .D(out_d),
        .Q(u11_q)
    );

    // U12: DAC
    wire [3:0] vol_nib  = u11_q[7:4];
    wire [3:0] wave_nib = u11_q[3:0];
    wire       io1, io2, io3, io4;

    cd4066 u_u12 (
        .CTRL1(vol_nib[0]), .CTRL2(vol_nib[1]),
        .CTRL3(vol_nib[2]), .CTRL4(vol_nib[3]),
        .IO1A(wave_nib[0]), .IO1B(io1),
        .IO2A(wave_nib[1]), .IO2B(io2),
        .IO3A(wave_nib[2]), .IO3B(io3),
        .IO4A(wave_nib[3]), .IO4B(io4)
    );

    assign dac_out = {4'd0, wave_nib} * {4'd0, vol_nib};

endmodule
