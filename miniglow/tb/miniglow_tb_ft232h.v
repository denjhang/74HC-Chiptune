//==============================================================================
// miniglow/tb/miniglow_tb_ft232h.v — FT232H 下载/运行复用测试
//------------------------------------------------------------------------------
// 验证 FT232H 复用架构（docs/ft232h-comm.md）：
//
// 测试 1: MODE=0 下载（FT232H 直驱 SRAM，CPU 高阻）
//   - 上电 MODE=0，CPU 复位
//   - FT232H 通过 FT_D/FT_A/FT_WE_n 写若干字节进 SRAM
//   - 拉高 MODE=1，解除复位，CPU 跑起来
//   - CPU 读 SRAM 内容验证下载成功
//
// 测试 2: MODE=1 通信（CPU 写 IO_OUT，FT232H 从 FT_D 读）
//   - CPU 执行程序：写 0x7E 到 IO_OUT
//   - TB 监测 FT_D 是否出现 0x7E
//
// 测试 3: MODE 切换不丢 SRAM 内容
//   - MODE=0 写 → MODE=1 → CPU 读同一地址验证
//==============================================================================
`timescale 1ns/1ps

module miniglow_tb_ft232h;
    reg CLK = 0;
    reg RST_n = 0;
    reg MODE = 1'b0;          // 开机 MODE=0（下载态）

    // FT232H 接口（TB 当上位机）
    reg  [7:0]  FT_D_drv = 8'hzz;   // TB 驱动 FT_D（MODE=0 时写 SRAM，MODE=1 时高阻）
    wire [7:0]  FT_D;                // inout：dut 和 TB 分时驱动
    reg  [18:0] FT_A = 0;
    reg         FT_WE_n = 1'b1;
    reg         FT_OE_n = 1'b1;
    reg         FT_CE_n = 1'b1;
    wire [7:0]  dbg_FT_D_drv;

    // TB 仅在 MODE=0 时驱动 FT_D（写 SRAM），MODE=1 时高阻让 dut 驱动
    assign FT_D = (MODE == 1'b0) ? FT_D_drv : 8'hzz;

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

    // FT_D 总线仲裁：MODE=0 时 TB 驱动，MODE=1 时 CPU 驱动（dut 内部已处理）
    // 但 inout 只能一方驱动：MODE=0 时 dut 把 FT_D 设高阻，TB 驱动
    assign FT_D = (MODE == 1'b0) ? FT_D_drv : 8'hzz;

    miniglow_top dut (
        .CLK(CLK), .RST_n(RST_n), .MODE(MODE),
        .FT_D(FT_D), .FT_A(FT_A), .FT_WE_n(FT_WE_n), .FT_OE_n(FT_OE_n), .FT_CE_n(FT_CE_n),
        .AUDIO_OUT(AUDIO_OUT),
        .CP_REG_IDX(CP_REG_IDX), .CP_REG_DATA(CP_REG_DATA),
        .CP_WE(CP_WE), .CP_OE(CP_OE), .CP_INT_n(CP_INT_n),
        .dbg_PC(dbg_PC), .dbg_opcode(dbg_opcode), .dbg_xx(dbg_xx),
        .dbg_A(dbg_A), .dbg_B(dbg_B), .dbg_RA(dbg_RA), .dbg_SEG(dbg_SEG),
        .dbg_DB(dbg_DB), .dbg_ALU_S(dbg_ALU_S), .dbg_ZERO(dbg_ZERO),
        .dbg_IO_OUT(dbg_IO_OUT), .dbg_AUDIO_OUT(dbg_AUDIO_OUT), .dbg_FT_D_drv(dbg_FT_D_drv)
    );

    always #5 CLK = ~CLK;

    // 模拟 FT232H 写一字节进 SRAM（MODE=0）
    // miniglow_ram 同步写：在 posedge CLK 时 CE_n=0,WE_n=0 锁存
    task ft232h_write_sram;
        input [18:0] addr;
        input [7:0]  data;
        begin
            @(negedge CLK);          // 先在低半周准备好
            FT_A     = addr;
            FT_D_drv = data;
            FT_CE_n  = 1'b0;
            FT_OE_n  = 1'b1;
            FT_WE_n  = 1'b0;
            @(posedge CLK);          // 这个 posedge 触发 RAM 写
            @(negedge CLK);
            FT_WE_n  = 1'b1;
            FT_CE_n  = 1'b1;
            FT_D_drv = 8'hzz;
        end
    endtask

    integer i;
    reg [7:0] expected_val;
    initial begin
        $display("===== miniglow FT232H download/comm test =====");

        //==========================================================
        // 阶段 1: MODE=0 下载 —— FT232H 写 SRAM，CPU 高阻
        //==========================================================
        $display("--- Phase 1: MODE=0 download (FT232H -> SRAM) ---");
        RST_n = 0;
        MODE  = 0;
        repeat (2) @(posedge CLK);

        // 通过 FT232H 写几个字节到 SRAM（SEG=1 RF 段，地址 0x10000）
        ft232h_write_sram(19'h00000, 8'hC3);   // SRAM[0x00000] = 0xC3
        ft232h_write_sram(19'h00001, 8'h81);   // SRAM[0x00001] = 0x81
        ft232h_write_sram(19'h01000, 8'h5A);   // SRAM[0x01000] = 0x5A（数据，CPU 跑起来读）

        // 验证 SRAM 内容（直接查 U_RAM.mem）
        @(negedge CLK);
        if (dut.U_RAM.mem[19'h00000] === 8'hC3)
            $display("[PASS] SRAM[0x00000] = 0xC3 (FT232H write ok)");
        else
            $display("[FAIL] SRAM[0x00000] = %02x (expect 0xC3)", dut.U_RAM.mem[19'h00000]);

        if (dut.U_RAM.mem[19'h00001] === 8'h81)
            $display("[PASS] SRAM[0x00001] = 0x81");
        else
            $display("[FAIL] SRAM[0x00001] = %02x (expect 0x81)", dut.U_RAM.mem[19'h00001]);

        if (dut.U_RAM.mem[19'h01000] === 8'h5A)
            $display("[PASS] SRAM[0x01000] = 0x5A (data write ok)");
        else
            $display("[FAIL] SRAM[0x01000] = %02x (expect 0x5A)", dut.U_RAM.mem[19'h01000]);

        //==========================================================
        // 阶段 2: 切 MODE=1，CPU 跑程序读下载的数据 + 写 IO_OUT
        //==========================================================
        $display("--- Phase 2: MODE=1 run (CPU reads downloaded data + outputs) ---");
        @(negedge CLK);
        MODE  = 1;       // 切运行态
        RST_n = 1;       // 解除复位

        // CPU 程序：读 SRAM[0x01000]（SEG=0 段 RA=0x1000）→ 输出到 AUDIO_OUT（音频口）
        // 同时通过 SEG=3 段 RAM 写 IO_OUT（FT232H 通信通道），验证两条独立通路
        dut.PROG_ROM[0] = 16'h0C00;   // SEG = 0
        dut.PROG_ROM[1] = 16'h0200;   // RA_L = 0x00
        dut.PROG_ROM[2] = 16'h0310;   // RA_H = 0x10  (RA = 0x1000)
        dut.PROG_ROM[3] = 16'h31FF;   // A = RAM       (读 SRAM[0x01000] = 0x5A)
        dut.PROG_ROM[4] = 16'h0A7E;   // IO0 = 0x7E    (写音频口 AUDIO_OUT)
        dut.PROG_ROM[5] = 16'h0C03;   // SEG = 3       (切到 FT232H 通信段)
        dut.PROG_ROM[6] = 16'h0200;   // RA_L = 0x00   (选 IO_OUT 寄存器)
        dut.PROG_ROM[7] = 16'h0300;   // RA_H = 0x00
        dut.PROG_ROM[8] = 16'h085A;   // RAM = 0x5A    (写 IO_OUT=0x5A 给 FT232H)
        dut.PROG_ROM[9] = 16'hFFFF;

        // 跑几个周期，等 CPU 把数据读出来并输出
        for (i = 0; i < 16; i = i + 1) begin
            @(negedge CLK);
            $display("cyc %0d: PC=%04x op=%02x xx=%02x A=%02x IO_OUT=%02x FT_D=%02x",
                i, dbg_PC, dbg_opcode, dbg_xx, dbg_A, dbg_IO_OUT, FT_D);
        end

        //==========================================================
        // 验证阶段 2：两条独立通路
        //==========================================================
        $display("----- verify phase 2 -----");
        if (dbg_A === 8'h5A)
            $display("[PASS] A = 0x5A (CPU read downloaded data from SRAM[0x1000])");
        else
            $display("[FAIL] A = %02x (expect 0x5A)", dbg_A);

        // 通路 1：AUDIO_OUT（IO0 = 0x7E，独立音频输出口 → TLC7524）
        if (AUDIO_OUT === 8'h7E)
            $display("[PASS] AUDIO_OUT = 0x7E (IO0=0x7E to audio port)");
        else
            $display("[FAIL] AUDIO_OUT = %02x (expect 0x7E)", AUDIO_OUT);

        // 通路 2：FT_D（SEG=3 段 IO_OUT=0x5A，FT232H 通信通道）
        if (FT_D === 8'h5A)
            $display("[PASS] FT_D = 0x5A (SEG=3 IO_OUT to FT232H comm channel)");
        else
            $display("[FAIL] FT_D = %02x (expect 0x5A)", FT_D);

        //==========================================================
        // 阶段 3: MODE 切换不丢 SRAM（再切回 MODE=0 读一下）
        //==========================================================
        $display("--- Phase 3: MODE switch preserves SRAM ---");
        @(negedge CLK);
        MODE  = 0;       // 切回下载态
        RST_n = 0;       // CPU 高阻
        repeat (2) @(posedge CLK);

        if (dut.U_RAM.mem[19'h01000] === 8'h5A)
            $display("[PASS] SRAM[0x01000] = 0x5A preserved after MODE toggle");
        else
            $display("[FAIL] SRAM[0x01000] = %02x (expect 0x5A preserved)", dut.U_RAM.mem[19'h01000]);

        $finish;
    end
endmodule
