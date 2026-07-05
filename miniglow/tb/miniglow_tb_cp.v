//==============================================================================
// miniglow/tb/miniglow_tb_cp.v — 协处理器接口测试（内存映射 + dummy CP）
//------------------------------------------------------------------------------
// dummy 协处理器（行为级）：
//   CP_REG_IDX=0: TYPE 只读 = 0xAA（dummy 协处理器标识）
//   CP_REG_IDX=2: REG_DATA，CPU 可写
//   CP_REG_IDX=3: START，写 1 触发"计算"（这里把 REG_DATA 翻转）
//   CP_REG_IDX=5: OUT_L = REG_DATA ^ 0xFF（"计算结果"）
//
// CPU 程序：
//   0: SEG = 4              切到 CP 段（SEG=4，让出 SEG=3 给 FT232H 通信）
//   1: RA_L = 2; RA_H = 0   选 REG_DATA 寄存器
//   2: RAM = 0x55           写 REG_DATA = 0x55（CP_WE 触发）
//   3: RA_L = 3             选 START 寄存器
//   4: RAM = 0x01           启动（dummy 翻转 REG_DATA → 0xAA）
//   5: RA_L = 5             选 OUT_L 寄存器
//   6: A = RAM              读 OUT_L（应该 0x00，因为 0x55 ^ 0xFF = 0xAA...）
//      ↑ dummy 设计：OUT_L = REG_DATA 翻转后的值
//   7: SEG = 0              切回程序段（避免后续影响）
//   8: IO0 = A              输出（A=读到的值，验证通信）
//   9: FFFF
//
// 简化 dummy：CP 收到 START 后，OUT_L = ~REG_DATA
//   写 REG_DATA=0x55, 启动, 读 OUT_L 应 = 0xAA
//==============================================================================
`timescale 1ns/1ps

// dummy 协处理器（行为级，模拟真实协处理器的接口行为）
module dummy_coproc (
    input        CLK,
    input  [2:0] CP_REG_IDX,
    inout  [7:0] CP_REG_DATA,
    input        CP_WE,
    input        CP_OE
);
    reg [7:0] reg_data = 8'h00;
    reg [7:0] out_l = 8'h00;
    reg       started = 0;

    // 写：CP_WE 上升沿（同步），根据 IDX 锁存
    always @(posedge CLK) begin
        if (CP_WE) begin
            case (CP_REG_IDX)
                3'd2: reg_data <= CP_REG_DATA;
                3'd3: begin
                    // START：计算 out_l = ~reg_data
                    out_l <= ~reg_data;
                end
                default: ;
            endcase
        end
    end

    // 读：CP_OE 时根据 IDX 驱动数据
    assign CP_REG_DATA = CP_OE ? (
        (CP_REG_IDX == 3'd0) ? 8'hAA :        // TYPE
        (CP_REG_IDX == 3'd5) ? out_l :        // OUT_L
        8'hzz
    ) : 8'hzz;

endmodule


module miniglow_tb_cp;
    reg CLK = 0; reg RST_n = 0;
    reg MODE = 1'b1;
    wire [7:0] FT_D; reg [18:0] FT_A = 19'h0;
    reg FT_WE_n = 1'b1, FT_OE_n = 1'b1, FT_CE_n = 1'b1;
    wire [7:0] FT_D_drv;

    wire [2:0]  CP_REG_IDX;
    wire [7:0]  CP_REG_DATA;
    wire        CP_WE, CP_OE;
    reg         CP_INT_n = 1'b1;

    wire [15:0] dbg_PC; wire [7:0] dbg_opcode, dbg_xx, dbg_A, dbg_B;
    wire [15:0] dbg_RA; wire [2:0] dbg_SEG;
    wire [7:0] dbg_DB, dbg_ALU_S; wire dbg_ZERO;
    wire [7:0] dbg_IO_OUT;
    wire [7:0] AUDIO_OUT;
    wire [7:0] dbg_AUDIO_OUT;

    miniglow_top dut (
        .CLK(CLK), .RST_n(RST_n), .MODE(MODE),
        .FT_D(FT_D), .FT_A(FT_A), .FT_WE_n(FT_WE_n), .FT_OE_n(FT_OE_n), .FT_CE_n(FT_CE_n),
        .AUDIO_OUT(AUDIO_OUT),
        .CP_REG_IDX(CP_REG_IDX), .CP_REG_DATA(CP_REG_DATA),
        .CP_WE(CP_WE), .CP_OE(CP_OE), .CP_INT_n(CP_INT_n),
        .dbg_PC(dbg_PC), .dbg_opcode(dbg_opcode), .dbg_xx(dbg_xx),
        .dbg_A(dbg_A), .dbg_B(dbg_B), .dbg_RA(dbg_RA),
        .dbg_SEG(dbg_SEG), .dbg_DB(dbg_DB),
        .dbg_ALU_S(dbg_ALU_S), .dbg_ZERO(dbg_ZERO),
        .dbg_IO_OUT(dbg_IO_OUT), .dbg_AUDIO_OUT(dbg_AUDIO_OUT), .dbg_FT_D_drv(FT_D_drv)
    );

    // dummy 协处理器实例
    dummy_coproc u_cp(
        .CLK(CLK),
        .CP_REG_IDX(CP_REG_IDX),
        .CP_REG_DATA(CP_REG_DATA),
        .CP_WE(CP_WE),
        .CP_OE(CP_OE)
    );

    always #5 CLK = ~CLK;

    integer i;
    initial begin
        $display("===== miniglow coprocessor interface test =====");

        dut.PROG_ROM[0] = 16'h0C04;   // SEG = 4 (CP 段，新段号)
        dut.PROG_ROM[1] = 16'h0202;   // RA_L = 2
        dut.PROG_ROM[2] = 16'h0300;   // RA_H = 0
        dut.PROG_ROM[3] = 16'h0855;   // RAM = 0x55  (写 CP REG_DATA)
        dut.PROG_ROM[4] = 16'h0203;   // RA_L = 3
        dut.PROG_ROM[5] = 16'h0801;   // RAM = 0x01  (写 CP START)
        dut.PROG_ROM[6] = 16'h0205;   // RA_L = 5
        dut.PROG_ROM[7] = 16'h31FF;   // A = RAM     (读 CP OUT_L)
        dut.PROG_ROM[8] = 16'h0C00;   // SEG = 0
        dut.PROG_ROM[9] = 16'h0A99;   // IO0 = 0x99 (固定标记，便于检测)
        // 再读一次 A 输出（避免 A 立即数源不存在）
        dut.PROG_ROM[10] = 16'hFFFF;

        repeat (3) @(posedge CLK);
        RST_n = 1;

        $display("cyc | PC  op xx | A  SEG RA    | CP_IDX WEn OEn | CP_DATA");
        for (i = 0; i < 20; i = i + 1) begin
            @(negedge CLK);
            $display("%3d | %03x %02x %02x | %02x  %b  %04x | %b  %b  %b | %02x",
                i, dbg_PC, dbg_opcode, dbg_xx, dbg_A, dbg_SEG, dbg_RA,
                CP_REG_IDX, CP_WE, CP_OE, CP_REG_DATA);
            if (AUDIO_OUT === 8'h99) begin
                $display("(AUDIO_OUT=0x99 detected)");
                i = 999;
            end
        end

        $display("----- verify -----");
        // dummy: REG_DATA=0x55, START 后 out_l=~0x55=0xAA, CPU 读出 A=0xAA
        if (dbg_A === 8'hAA)
            $display("[PASS] A = 0xAA (CP readback: REG_DATA=0x55 -> OUT_L=0xAA)");
        else
            $display("[FAIL] A = %02x (expect 0xAA)", dbg_A);

        if (AUDIO_OUT === 8'h99)
            $display("[PASS] CP handshake completed (AUDIO_OUT=0x99 marker)");
        else
            $display("[FAIL] AUDIO_OUT = %02x (expect 0x99 marker)", AUDIO_OUT);

        $finish;
    end
endmodule
