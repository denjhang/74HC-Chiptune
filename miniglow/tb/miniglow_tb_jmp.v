//==============================================================================
// miniglow/tb/miniglow_tb_jmp.v — 跳转测试（JMP + JCC）
//------------------------------------------------------------------------------
// 测试 1: JMP 无条件跳转 + 计数循环
//   loop: B = B + 1（用 ALU ADD）
//         RA = loop_addr; JMP
//   预期: B 持续递增
//
// 测试 2: JCC 条件跳转（A==B 时跳，循环到计数器 == 阈值退出）
//
// 程序（PC = 字地址）:
//   0: A = 0
//   1: B = 0          // counter
//   2: SEG = 0        // (可选)
//   3: B = ALU[A_ADD_1] ?  → 暂用 A=A; A=ALU[ADD]; B=A  多步
//   简化：直接 B 加 1 用立即数 + ALU
//
//   简化测试 1（JMP）：
//   0: A = 0x01
//   1: B = 0x00
//   2: RA_L = 0x06    // 跳转目标低字节 = 6（loop 起点）
//   3: RA_H = 0x00
//   4: A = ALU[ADD]   // B = B + A（A=1 当增量）—— 但 ALU 是 A+B，要先换
//      ↑ 这里 ALU 算 A+B，结果存 A 会自增 A 不对。
//   改：用 A 当计数器，B 当增量
//   0: B = 0x01       // 增量
//   1: RA_L = 0x04    // loop 地址（PC=4）
//   2: RA_H = 0x00
//   3: PC <- RA       // JMP 第一次（到 PC=4）
//   4: A = ALU[ADD]   // loop: A = A + B（自增）
//   5: RA_L = 0x04    // 重设 RA_L（A 改了不影响 RA）
//   6: RA_H = 0x00
//   7: PC <- RA       // JMP 回 loop
//
// 简化测试 2（JCC 相等跳）：
//   先 A=counter, B=阈值
//   A = ALU[SUB]     // A - B
//   if (zero) goto done
//==============================================================================
`timescale 1ns/1ps
module miniglow_tb_jmp;
    reg CLK = 0; reg RST_n = 0;
    reg MODE = 1'b1;
    wire [7:0] FT_D; reg [18:0] FT_A = 19'h0;
    reg FT_WE_n = 1'b1, FT_OE_n = 1'b1, FT_CE_n = 1'b1;
    wire [7:0] FT_D_drv;
    wire [2:0] CP_REG_IDX; wire [7:0] CP_REG_DATA;
    wire CP_WE, CP_OE; reg CP_INT_n = 1'b1;
    wire [15:0] dbg_PC; wire [7:0] dbg_opcode, dbg_xx, dbg_A, dbg_B;
    wire [15:0] dbg_RA; wire [2:0] dbg_SEG;
    wire [7:0] dbg_DB, dbg_ALU_S; wire dbg_ZERO;
    wire [7:0] dbg_IO_OUT;
    wire [7:0] AUDIO_OUT;
    wire [7:0] dbg_AUDIO_OUT;

    miniglow_top dut(
        .CLK(CLK), .RST_n(RST_n), .MODE(MODE),
        .FT_D(FT_D), .FT_A(FT_A), .FT_WE_n(FT_WE_n), .FT_OE_n(FT_OE_n), .FT_CE_n(FT_CE_n),
        .AUDIO_OUT(AUDIO_OUT),
        .CP_REG_IDX(CP_REG_IDX), .CP_REG_DATA(CP_REG_DATA),
        .CP_WE(CP_WE), .CP_OE(CP_OE), .CP_INT_n(CP_INT_n),
        .dbg_PC(dbg_PC), .dbg_opcode(dbg_opcode), .dbg_xx(dbg_xx),
        .dbg_A(dbg_A), .dbg_B(dbg_B), .dbg_RA(dbg_RA), .dbg_SEG(dbg_SEG),
        .dbg_DB(dbg_DB), .dbg_ALU_S(dbg_ALU_S), .dbg_ZERO(dbg_ZERO),
        .dbg_IO_OUT(dbg_IO_OUT), .dbg_AUDIO_OUT(dbg_AUDIO_OUT), .dbg_FT_D_drv(FT_D_drv)
    );
    always #5 CLK = ~CLK;

    integer i;
    initial begin
        $display("===== miniglow JMP test =====");

        // 程序：A 自增循环（B=1 增量，JMP 回 loop）
        dut.PROG_ROM[0] = 16'h0601;   // B = 0x01  (增量)
        dut.PROG_ROM[1] = 16'h0204;   // RA_L = 0x04
        dut.PROG_ROM[2] = 16'h0300;   // RA_H = 0x00
        dut.PROG_ROM[3] = 16'h07FF;   // PC <- RA (JMP 到 PC=4)
        dut.PROG_ROM[4] = 16'h1100;   // loop: A = ALU[ADD]   (A += B)
        dut.PROG_ROM[5] = 16'h0204;   // RA_L = 0x04 (重设)
        dut.PROG_ROM[6] = 16'h0300;   // RA_H = 0x00
        dut.PROG_ROM[7] = 16'h07FF;   // JMP loop

        repeat (3) @(posedge CLK);
        RST_n = 1;

        $display("cyc | PC   op xx  | A  B  | ALU Z");
        for (i = 0; i < 40; i = i + 1) begin
            @(negedge CLK);
            $display("%3d | %04x %02x %02x | %02x %02x | %02x  %b",
                i, dbg_PC, dbg_opcode, dbg_xx, dbg_A, dbg_B, dbg_ALU_S, dbg_ZERO);
        end

        $display("----- verify -----");
        // 循环里 A 每次 +1，40 拍后 A 应该 >= 4
        if (dbg_A >= 8'd4)
            $display("[PASS] A = %0d (counter incremented via JMP loop)", dbg_A);
        else
            $display("[FAIL] A = %0d (expect >= 4)", dbg_A);

        $finish;
    end
endmodule
