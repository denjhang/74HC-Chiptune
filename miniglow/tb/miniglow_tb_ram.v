//==============================================================================
// miniglow/tb/miniglow_tb_ram.v — RAM 读写测试
//------------------------------------------------------------------------------
// 1. 设 RA = 0x0100（SEG=0 段，避开 PROG_ROM，写 RF 段 1）
//    实际 SEG=1 段是 RF 区，用 SEG=1 写
// 2. RAM[RA] = 0x42   (dst=8, src=imm, 机器码 0842)
// 3. A = RAM[RA]      (src=RAM, dst=A, 机器码 31FF)
// 4. IO0 = A          不直接，A 立即数源不存在
//    改用 A = RAM 后再写到 IO0？但 IO0=A 没有（A 不是源）
//    萤火虫原版 A 不是源——必须经 RF 或 ALU
//    这里：A = RAM; B = A（同问题）
//    简单：RAM = 0x55 直接 IO0 = RAM 读出
//
// 程序:
//   0: SEG = 1          切到 RF 段（SEG_r = 1，地址 = 0x10000+RA）
//   1: RA_L = 0x00
//   2: RA_H = 0x00      RA = 0x0000
//   3: RAM = 0x55       (0855) 写 RAM[0x10000] = 0x55
//   4: A = RAM          (31FF) A = RAM[0x10000] = 0x55
//   5: RAM = A          (08xx 不能写 A，src=A 不存在)
//      ↑ 直接读 RAM 到 IO0? IO0 = RAM (3AFF)
//   5: IO0 = RAM        (3AFF) IO0 = RAM[0x10000]
//   6: FFFF
//==============================================================================
`timescale 1ns/1ps
module miniglow_tb_ram;
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
        $display("===== miniglow RAM read/write test =====");

        dut.PROG_ROM[0] = 16'h0C01;   // SEG = 1（切到 RF 段）
        dut.PROG_ROM[1] = 16'h0200;   // RA_L = 0x00
        dut.PROG_ROM[2] = 16'h0300;   // RA_H = 0x00  (RA = 0x0000, SEG=1 → SRAM addr 0x10000)
        dut.PROG_ROM[3] = 16'h0855;   // RAM = 0x55  (写 0x55 到 SRAM[0x10000])
        dut.PROG_ROM[4] = 16'h31FF;   // A = RAM     (读 SRAM[0x10000] 到 A)
        dut.PROG_ROM[5] = 16'h3AFF;   // IO0 = RAM   (读 SRAM[0x10000] 到 IO0)
        dut.PROG_ROM[6] = 16'hFFFF;

        repeat (3) @(posedge CLK);
        RST_n = 1;

        $display("cyc | PC  op xx | A  SEG RA    | DB | WEn");
        for (i = 0; i < 14; i = i + 1) begin
            @(negedge CLK);
            $display("%3d | %03x %02x %02x | %02x  %b  %04x | %02x | %b",
                i, dbg_PC, dbg_opcode, dbg_xx, dbg_A, dbg_SEG, dbg_RA, dbg_DB,
                dut.SRAM_WE_n);
        end

        $display("----- verify -----");
        if (dut.U_RAM.mem[19'h10000] === 8'h55)
            $display("[PASS] SRAM[0x10000] = 0x55 (write ok)");
        else
            $display("[FAIL] SRAM[0x10000] = %02x (expect 0x55)", dut.U_RAM.mem[19'h10000]);

        if (dbg_A === 8'h55)
            $display("[PASS] A = 0x55 (RAM read to A ok)");
        else
            $display("[FAIL] A = %02x (expect 0x55)", dbg_A);

        if (AUDIO_OUT === 8'h55)
            $display("[PASS] AUDIO_OUT = 0x55 (RAM read to audio port ok)");
        else
            $display("[FAIL] AUDIO_OUT = %02x (expect 0x55)", AUDIO_OUT);

        $finish;
    end
endmodule
