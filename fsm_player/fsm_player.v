// fsm_player.v - 双 ROM 自动播放器 (全芯片实例化)
//
// 芯片清单:
//   5× 74HC161  — 20-bit 地址计数器 (级联)
//   2× 39SF040  — 程序 ROM + 数据 ROM (各 512KB)
//   1× 74HC273  — 数据输出锁存
//   1× 74HC04   — 反相器 (产生 /MR 等控制信号)
//
// 功能: 上电后从地址 0 开始自动顺序读取 ROM, 输出 16-bit 数据

`timescale 1ns/1ps

module fsm_player (
    input  wire        CLK,      // 主时钟
    input  wire        RST_n,    // 复位 (低有效)
    output wire [15:0] DATA_OUT, // 16-bit 数据输出
    output wire        PLAYING   // 播放中标志
);

    // ============================================================
    // 控制信号生成
    // ============================================================
    wire clk   = CLK;
    wire rst_n = RST_n;  // 低有效复位, 直通给 161 MR 和 273 MR_n

    // 74HC04 — U_INV: 暂时空置, 预留给 FSM 控制信号
    wire inv_unused;
    hc04 u_inv (
        .A1(1'b0), .Y1(inv_unused),
        .A2(1'b0),  .Y2(),
        .A3(1'b0),  .Y3(),
        .A4(1'b0),  .Y4(),
        .A5(1'b0),  .Y5(),
        .A6(1'b0),  .Y6()
    );

    // ============================================================
    // 20-bit 地址计数器: 5× 74HC161 级联
    //   U_CNT0: addr[3:0]   (最低 4 位)
    //   U_CNT1: addr[7:4]
    //   U_CNT2: addr[11:8]
    //   U_CNT3: addr[15:12]
    //   U_CNT4: addr[19:16] (最高 4 位)
    //
    // 级联规则:
    //   - 所有 161 共享 CLK, MR (= rst), PE=1 (不预置)
    //   - CNT0: CEP=1, CET=1 (始终计数)
    //   - CNT1-4: CEP=前级 TC, CET=1
    // ============================================================
    wire [3:0] cnt0_q, cnt1_q, cnt2_q, cnt3_q, cnt4_q;
    wire       tc0, tc1, tc2, tc3, tc4;

    // U_CNT0 — addr[3:0]
    hc161 u_cnt0 (
        .MR(rst_n),  .CP(clk),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(cnt0_q[0]), .Q1(cnt0_q[1]), .Q2(cnt0_q[2]), .Q3(cnt0_q[3]),
        .CEP(1'b1), .CET(1'b1),
        .PE(1'b1),  .TC(tc0)
    );

    // U_CNT1 — addr[7:4]
    hc161 u_cnt1 (
        .MR(rst_n),  .CP(clk),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(cnt1_q[0]), .Q1(cnt1_q[1]), .Q2(cnt1_q[2]), .Q3(cnt1_q[3]),
        .CEP(1'b1), .CET(tc0),
        .PE(1'b1),  .TC(tc1)
    );

    // U_CNT2 — addr[11:8]
    hc161 u_cnt2 (
        .MR(rst_n),  .CP(clk),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(cnt2_q[0]), .Q1(cnt2_q[1]), .Q2(cnt2_q[2]), .Q3(cnt2_q[3]),
        .CEP(1'b1), .CET(tc1),
        .PE(1'b1),  .TC(tc2)
    );

    // U_CNT3 — addr[15:12]
    hc161 u_cnt3 (
        .MR(rst_n),  .CP(clk),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(cnt3_q[0]), .Q1(cnt3_q[1]), .Q2(cnt3_q[2]), .Q3(cnt3_q[3]),
        .CEP(1'b1), .CET(tc2),
        .PE(1'b1),  .TC(tc3)
    );

    // U_CNT4 — addr[19:16]
    hc161 u_cnt4 (
        .MR(rst_n),  .CP(clk),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0),
        .Q0(cnt4_q[0]), .Q1(cnt4_q[1]), .Q2(cnt4_q[2]), .Q3(cnt4_q[3]),
        .CEP(1'b1), .CET(tc3),
        .PE(1'b1),  .TC(tc4)
    );

    // 20-bit 地址总线 (声明为 wire 以便 testbench 层次访问)
    wire [19:0] addr;
    assign addr = {cnt4_q, cnt3_q, cnt2_q, cnt1_q, cnt0_q};

    // ============================================================
    // ROM1: 程序 ROM — 39SF040 (512K×8)
    //   地址: addr[18:0]
    //   数据: 8-bit
    // ============================================================
    wire [7:0] rom1_dq;

    hc39sf040 #(
        .INIT_FILE("rom/fsm_prog.hex")
    ) u_rom1 (
        .A0(addr[0]),  .A1(addr[1]),  .A2(addr[2]),  .A3(addr[3]),
        .A4(addr[4]),  .A5(addr[5]),  .A6(addr[6]),  .A7(addr[7]),
        .A8(addr[8]),  .A9(addr[9]),  .A10(addr[10]), .A11(addr[11]),
        .A12(addr[12]), .A13(addr[13]), .A14(addr[14]), .A15(addr[15]),
        .A16(addr[16]), .A17(addr[17]), .A18(addr[18]),
        .DQ(rom1_dq),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // ============================================================
    // ROM2: 数据 ROM — 39SF040 (512K×8)
    //   地址: addr[18:0] (同 ROM1, 可改接不同地址)
    //   数据: 8-bit
    // ============================================================
    wire [7:0] rom2_dq;

    hc39sf040 #(
        .INIT_FILE("rom/fsm_data.hex")
    ) u_rom2 (
        .A0(addr[0]),  .A1(addr[1]),  .A2(addr[2]),  .A3(addr[3]),
        .A4(addr[4]),  .A5(addr[5]),  .A6(addr[6]),  .A7(addr[7]),
        .A8(addr[8]),  .A9(addr[9]),  .A10(addr[10]), .A11(addr[11]),
        .A12(addr[12]), .A13(addr[13]), .A14(addr[14]), .A15(addr[15]),
        .A16(addr[16]), .A17(addr[17]), .A18(addr[18]),
        .DQ(rom2_dq),
        .CE_n(1'b0), .OE_n(1'b0), .WE_n(1'b1)
    );

    // ============================================================
    // 数据输出锁存 — 74HC273 (8-bit D 触发器)
    //   每个 CLK 上升沿锁存 ROM1 输出
    //   ROM2 高字节暂未使用, DATA_OUT[15:8] = 0
    // ============================================================
    wire [7:0] rom1_out;

    // 39SF040 DQ 是 inout, 需要锁存避免高阻
    // 当 CE_n=0, OE_n=0 时 DQ 驱动 mem[addr]
    // 用 273 在 CLK 上升沿锁存
    hc273 #(.WIDTH(8)) u_latch_lo (
        .MR_n(rst_n),
        .CP(clk),
        .D(rom1_dq),
        .Q(rom1_out)
    );

    assign DATA_OUT = {8'b0, rom1_out};
    assign PLAYING  = (addr != 20'b0);

endmodule
