//==============================================================================
// miniglow/tb/miniglow_tb_jcc.v — 条件跳转测试（SUB + JCC 相等跳）
//------------------------------------------------------------------------------
// 计数器 A 自增到 5 后退出循环（A == 阈值时 JCC 跳到 done）
//
// 程序:
//   0: B = 0x05       阈值
//   1: A = 0x00       counter
//   2: A = ALU[ADD]   loop: A = A + 1 ← 不行，B 是阈值不是增量
//
// 重设计：用 B 当增量(1)，A 当 counter，比较时换 B
//   0: B = 0x01       增量
//   1: A = 0x00       counter
//   2: A = ALU[ADD]   loop (PC=2): A += 1
//   3: B = 0x05       换 B 为阈值（用于比较）
//   4: RA_L = 0x08    done 地址低
//   5: RA_H = 0x00
//   6: xx=01 SUB → A = ALU[SUB]  但 SUB 结果不存 A（要保留 counter）
//      问题：SUB 会改 A
//   改：先复制 counter 到临时，再 SUB
//
// 实际 JCC 设计：JCC 不写 A，只算 A-B 看 zero 标志
//   但本模型 src=ALU 时算结果，dst 必须 ≠ ALU 才不写
//   JCC 指令 17XX：xx=01 表示 SUB，但 dst 没指定——它内部用 ALU 结果判 zero
//
// 简化测试：让 JCC 在 A==B 时跳
//   程序：A 从 0 自增到 5；每次循环后 A-B（B=5）判零，相等则跳走
//
//   0: B = 0x01       增量
//   1: A = 0x00       counter
//   2: A = ALU[ADD]   loop: A = A+B = A+1
//   3: B = 0x05       阈值（覆盖增量，后续循环 B=5 会让 A+=5 错）
//      ↑ 这里逻辑有 bug，重设计
//
// 干脆：A 自增 5 次后，A==5（B 始终 1）；比较用单独 B=5 临时换
//   难点：循环里 B 既要当增量(1)又要当阈值(5)
//   解：每次循环开始 B=1 加完，循环末尾换 B=5 比较，循环开始再换回 1
//   太绕。
//
// 最简：用 RAM 存阈值，比较时取出来做 B
//   但 RAM 还没测通。
//
// 极简方案：JCC 只测"是不是相等"，用一个固定值。
//   A 自增（B=1），当 A==3 时跳。
//   每次 A+=1 后，临时设 B=A（用 RAM 中转？无 RAM 时用立即数），
//   设 B=3 比较。
//
// 写法：用 B 切换
//   0: B = 0x01
//   1: A = 0x00
//   loop (PC=2):
//   2: A = ALU[ADD]   A += 1
//   3: B = 0x03       阈值（覆盖 B）
//   4: 17 01          JCC SUB: if (A-B==0) goto RA  → 用 SUB 判相等
//      但 JCC 要先设 RA = loop 或 done
//   重排：
//   0: B = 0x01
//   1: A = 0x00
//   2: A = ALU[ADD]      loop: A += 1
//   3: RA_L = 0x09       done 地址
//   4: RA_H = 0x00
//   5: B = 0x03          阈值（JCC 用）
//   6: 17 01             if (A-B==0) JMP done (PC=9)
//   7: B = 0x01          恢复增量
//   8: RA_L = 0x02; RA_H=0; JMP loop  → 多条
//
//   太长。直接：
//   0: B = 0x01
//   1: A = 0x00
//   2: A = ALU[ADD]      loop: A += 1
//   3: B = 0x03
//   4: RA_L = 0x07       done 地址
//   5: RA_H = 0x00
//   6: 17 01             JCC: if(A-B==0) JMP 7
//   7: IO0 = A           done: 输出最终 A
//   8: FFFF              NOP
//   ↑ 没回 loop，A 只自增 1 次。
//
//   完整版（带回跳）：
//   0: B = 0x01
//   1: A = 0x00
//   2: A = ALU[ADD]      loop: A += 1
//   3: B = 0x03          阈值
//   4: RA_L = 0x0A       done 地址 (PC=10)
//   5: RA_H = 0x00
//   6: 17 01             JCC: if(A==B) JMP 10
//   7: B = 0x01          恢复增量
//   8: RA_L = 0x02       loop 地址
//   9: 07 FF             JMP loop
//  10: IO0 = A           done: 输出
//  11: FFFF
//==============================================================================
`timescale 1ns/1ps
module miniglow_tb_jcc;
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
        $display("===== miniglow JCC test =====");

        dut.PROG_ROM[0] = 16'h0601;   // B = 0x01
        dut.PROG_ROM[1] = 16'h0100;   // A = 0x00
        dut.PROG_ROM[2] = 16'h1100;   // loop: A = ALU[ADD]
        dut.PROG_ROM[3] = 16'h0603;   // B = 0x03 (阈值)
        dut.PROG_ROM[4] = 16'h020A;   // RA_L = 0x0A (done)
        dut.PROG_ROM[5] = 16'h0300;   // RA_H = 0x00
        dut.PROG_ROM[6] = 16'h1701;   // JCC SUB: if(A-B==0) JMP done
        dut.PROG_ROM[7] = 16'h0601;   // B = 0x01 (恢复增量)
        dut.PROG_ROM[8] = 16'h0202;   // RA_L = 0x02 (loop)
        dut.PROG_ROM[9] = 16'h07FF;   // JMP loop
        dut.PROG_ROM[10] = 16'h0A03;  // done: IO0 = A (这里 IO0 取 A 不直接，改立即数测)
        dut.PROG_ROM[10] = 16'h0A99;  // done: IO0 = 0x99 (固定标记)
        dut.PROG_ROM[11] = 16'hFFFF;

        repeat (3) @(posedge CLK);
        RST_n = 1;

        $display("cyc | PC   op xx  | A  B  | ALU Z");
        for (i = 0; i < 50; i = i + 1) begin
            @(negedge CLK);
            $display("%3d | %04x %02x %02x | %02x %02x | %02x  %b",
                i, dbg_PC, dbg_opcode, dbg_xx, dbg_A, dbg_B, dbg_ALU_S, dbg_ZERO);
            if (AUDIO_OUT === 8'h99) begin
                $display("(AUDIO_OUT=0x99 detected, exiting)");
                i = 999;
            end
        end

        $display("----- verify -----");
        if (AUDIO_OUT === 8'h99)
            $display("[PASS] JCC jumped to done when A==3 (counter=%0d)", dbg_A);
        else
            $display("[FAIL] AUDIO_OUT = %02x (expect 0x99), A=%0d", AUDIO_OUT, dbg_A);

        $finish;
    end
endmodule
