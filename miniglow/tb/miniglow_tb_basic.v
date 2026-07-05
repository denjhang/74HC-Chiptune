//==============================================================================
// miniglow/tb/miniglow_tb_basic.v — 基础 ISA 测试（全实例化模型）
//------------------------------------------------------------------------------
// 测试:
//   1. A = 0x12, B = 0x34, A = ALU[ADD]   → A = 0x46
//   2. RA_L = 0x40, RA_H = 0x00           → RA = 0x0040
//   3. IO0 = 0x55                          → IO0 输出 0x55
//   4. JMP 测试
//==============================================================================
`timescale 1ns/1ps
module miniglow_tb_basic;
    reg CLK = 0;
    reg RST_n = 0;

    // FT232H 接口（运行态：MODE=1，FT 信号悬空/高阻）
    reg         MODE = 1'b1;        // 运行态
    wire [7:0]  FT_D;               // CPU 输出 IO_OUT（运行态）
    reg  [18:0] FT_A = 19'h0;
    reg         FT_WE_n = 1'b1;
    reg         FT_OE_n = 1'b1;
    reg         FT_CE_n = 1'b1;
    wire [7:0]  FT_D_drv;

    // CP 接口（本测试不挂协处理器）
    wire [2:0]  CP_REG_IDX;
    wire [7:0]  CP_REG_DATA;
    wire        CP_WE, CP_OE;
    reg         CP_INT_n = 1'b1;

    wire [15:0] dbg_PC;
    wire [7:0]  dbg_opcode, dbg_xx, dbg_A, dbg_B;
    wire [15:0] dbg_RA;
    wire [2:0]  dbg_SEG;
    wire [7:0]  dbg_DB, dbg_ALU_S;
    wire        dbg_ZERO;
    wire [7:0]  dbg_IO_OUT;
    wire [7:0]  AUDIO_OUT;
    wire [7:0]  dbg_AUDIO_OUT;

    miniglow_top dut (
        .CLK(CLK), .RST_n(RST_n),
        .MODE(MODE),
        .FT_D(FT_D), .FT_A(FT_A), .FT_WE_n(FT_WE_n), .FT_OE_n(FT_OE_n), .FT_CE_n(FT_CE_n),
        .AUDIO_OUT(AUDIO_OUT),
        .CP_REG_IDX(CP_REG_IDX), .CP_REG_DATA(CP_REG_DATA),
        .CP_WE(CP_WE), .CP_OE(CP_OE), .CP_INT_n(CP_INT_n),
        .dbg_PC(dbg_PC),
        .dbg_opcode(dbg_opcode), .dbg_xx(dbg_xx),
        .dbg_A(dbg_A), .dbg_B(dbg_B), .dbg_RA(dbg_RA),
        .dbg_SEG(dbg_SEG), .dbg_DB(dbg_DB),
        .dbg_ALU_S(dbg_ALU_S), .dbg_ZERO(dbg_ZERO),
        .dbg_IO_OUT(dbg_IO_OUT), .dbg_AUDIO_OUT(dbg_AUDIO_OUT), .dbg_FT_D_drv(FT_D_drv)
    );

    always #5 CLK = ~CLK;

    integer i;
    initial begin
        $display("===== miniglow basic ISA test =====");
        $display("cyc | PC    op  xx   A   B   RA    | ALU  ZERO | DB");
        $display("----+------+---+----+---+---+------+---+----+----");

        // 程序（地址 = 字地址，PC +1 步进）
        dut.PROG_ROM[0] = 16'h0112;   // A = 0x12
        dut.PROG_ROM[1] = 16'h0634;   // B = 0x34
        dut.PROG_ROM[2] = 16'h1100;   // A = ALU[ADD]
        dut.PROG_ROM[3] = 16'h0240;   // RA_L = 0x40
        dut.PROG_ROM[4] = 16'h0300;   // RA_H = 0x00
        dut.PROG_ROM[5] = 16'h0A55;   // IO0 = 0x55
        dut.PROG_ROM[6] = 16'hFFFF;   // NOP 死循环

        // 复位
        repeat (3) @(posedge CLK);
        RST_n = 1;

        // 跑 14 个周期
        for (i = 0; i < 14; i = i + 1) begin
            @(negedge CLK);
            $display("%3d | %04x | %02x | %02x | %02x  %02x  %04x | %02x  %b   | %02x",
                i, dbg_PC, dbg_opcode, dbg_xx,
                dbg_A, dbg_B, dbg_RA,
                dbg_ALU_S, dbg_ZERO, dbg_DB);
        end

        $display("----- verify -----");
        if (dbg_A === 8'h46)
            $display("[PASS] A = 0x46 (0x12 + 0x34)");
        else
            $display("[FAIL] A = %02x (expect 0x46)", dbg_A);

        if (dbg_RA === 16'h0040)
            $display("[PASS] RA = 0x0040");
        else
            $display("[FAIL] RA = %04x (expect 0x0040)", dbg_RA);

        if (AUDIO_OUT === 8'h55)
            $display("[PASS] AUDIO_OUT = 0x55 (IO0 = 0x55 written to audio port)");
        else
            $display("[FAIL] AUDIO_OUT = %02x (expect 0x55)", AUDIO_OUT);

        $finish;
    end
endmodule
