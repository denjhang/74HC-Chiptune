// wsg3_func_tb.v — WSG3 功能验证
//
// 验证步骤:
//   1. SPFM 写入频率到 voice 1
//   2. SPFM 写入音量到 voice 1
//   3. SPFM 写入波形选择到 voice 1
//   4. 让 WSG 跑若干周期, 观察 DAC 输出
//   5. 检查 DAC 是否有非零输出 (有声音)
//
// 寄存器映射 (Pac-Man):
//   Voice 1 Waveform: 5045h (低 3 bit)
//   Voice 1 Freq:     5050h-5054h (20-bit, 低 nibble)
//   Voice 1 Volume:   5055h (低 nibble, 0-15)
//   Voice 1 Accumulator: 5040h-5044h
//
// 地址 0x45 = 波形, 0x50-0x54 = 频率, 0x55 = 音量

`timescale 1ns/1ps

module wsg3_func_tb;

    reg         SPFM_CLK = 0;
    reg         SPFM_RST_n = 0;
    reg  [7:0]  SPFM_D = 0;
    reg         SPFM_A0 = 0;
    reg         SPFM_CS_n = 1;
    reg         SPFM_WR_n = 1;
    reg         SPFM_RD_n = 1;

    wire [7:0]  dac_out;

    wsg3_core u_dut (
        .SPFM_CLK(SPFM_CLK),
        .SPFM_RST_n(SPFM_RST_n),
        .SPFM_D(SPFM_D),
        .SPFM_A0(SPFM_A0),
        .SPFM_CS_n(SPFM_CS_n),
        .SPFM_WR_n(SPFM_WR_n),
        .SPFM_RD_n(SPFM_RD_n),
        .dac_out(dac_out)
    );

    // 6.144 MHz 时钟 (Pac-Man 主时钟 / 32 = 192kHz 内部分频)
    always #81.38 SPFM_CLK = ~SPFM_CLK;

    // SPFM 写任务 (YM2413 风格双步写)
    //   地址步: A0=0, CS=0, WR=0 (24 cycles)
    //   间隙:   CS=1, WR=1 (8 cycles, 让 sync chain 复位)
    //   数据步: A0=1, CS=0, WR=0 (24 cycles)
    //   释放:   CS=1, WR=1 (4 cycles)
    task spfm_write;
        input [7:0] addr;
        input [7:0] data;
        integer k;
        reg [5:0] hcnt_before, hcnt_after;
        begin
            hcnt_before = u_dut.hcnt_r;
            // 地址步: A0=0, CS=0, WR=0
            SPFM_A0  = 1'b0;
            SPFM_D   = addr;
            SPFM_CS_n = 1'b0;
            SPFM_WR_n = 1'b0;
            for (k = 0; k < 24; k = k + 1) @(posedge SPFM_CLK);
            // 间隙: CS=1, WR=1 (复位 sync chain, 释放 spfm_write_active)
            SPFM_CS_n = 1'b1;
            SPFM_WR_n = 1'b1;
            for (k = 0; k < 8; k = k + 1) @(posedge SPFM_CLK);
            // 数据步: A0=1, CS=0, WR=0
            SPFM_A0  = 1'b1;
            SPFM_D   = data;
            SPFM_CS_n = 1'b0;
            SPFM_WR_n = 1'b0;
            for (k = 0; k < 24; k = k + 1) @(posedge SPFM_CLK);
            // 释放
            SPFM_WR_n = 1'b1;
            SPFM_CS_n = 1'b1;
            for (k = 0; k < 4; k = k + 1) @(posedge SPFM_CLK);
            hcnt_after = u_dut.hcnt_r;
            $display("  spfm_write(0x%02X, 0x%02X) hcnt %02X→%02X carry=%06b u7[0..4]=%b%b%b%b%b u6[5]=%b",
                     addr, data, hcnt_before, hcnt_after, u_dut.carry_chain,
                     u_dut.u_u7.mem[0], u_dut.u_u7.mem[1], u_dut.u_u7.mem[2],
                     u_dut.u_u7.mem[3], u_dut.u_u7.mem[4], u_dut.u_u6.mem[5]);
        end
    endtask

    integer i;
    integer nonzero_count;
    reg [7:0] dac_sample;
    integer fd;

    initial begin
        $display("=== WSG3 Functional Test ===");
        $dumpfile("wsg3_func.vcd");
        $dumpvars(0, wsg3_func_tb);

        // t=0 立即检查 mem 初始值
        $display("t=0: u6 mem[0]=%b u7 mem[0]=%b u6_we_n=%b data_wr=%b spfm_write=%b RST_n=%b",
                 u_dut.u_u6.mem[0], u_dut.u_u7.mem[0],
                 u_dut.u6_we_n, u_dut.data_wr_pulse_n, u_dut.spfm_write_active,
                 SPFM_RST_n);
        #1;
        $display("t=1: u6 mem[0]=%b u7 mem[0]=%b u6_we_n=%b",
                 u_dut.u_u6.mem[0], u_dut.u_u7.mem[0],
                 u_dut.u6_we_n);

        // 复位
        SPFM_RST_n = 0;
        #(81.38 * 20);
        $display("After RST=0: hc174.q_reg=%b acc=%b freq=%b adder_s=%b c4=%b",
                 u_dut.u_u9.q_reg, u_dut.acc_dout, u_dut.freq_dout,
                 u_dut.adder_s, u_dut.adder_c4);
        $display("  u6 mem[0]=%b u6_do_inv=%b u6_cs_n=%b u6_we_n=%b",
                 u_dut.u_u6.mem[0], u_dut.u6_do_inv, u_dut.u6_cs_n, u_dut.u6_we_n);
        // RST 释放前一刻的状态
        $display("  Before RST release: adder_s=%b c4=%b carry=%06b",
                 u_dut.adder_s, u_dut.adder_c4, u_dut.carry_chain);
        SPFM_RST_n = 1;
        #10;
        $display("  RST released +10ns: hc174.q=%b carry=%06b adder_s=%b acc=%b ram_din=%b",
                 u_dut.u_u9.q_reg, u_dut.carry_chain, u_dut.adder_s,
                 u_dut.acc_dout, u_dut.ram_din_inv);
        $display("    u6.mem[0]=%b addr=%b%b%b%b O0=%b O1=%b O2=%b O3=%b",
                 u_dut.u_u6.mem[0], u_dut.u_u6.A3, u_dut.u_u6.A2, u_dut.u_u6.A1, u_dut.u_u6.A0,
                 u_dut.u_u6.O0, u_dut.u_u6.O1, u_dut.u_u6.O2, u_dut.u_u6.O3);
        $display("    hc283: A=%b B=%b C0=%b S=%b C4=%b",
                 u_dut.u_u8.A, u_dut.u_u8.B, u_dut.u_u8.C0,
                 u_dut.u_u8.S, u_dut.u_u8.C4);
        $display("    acc_dout=%b freq_dout=%b", u_dut.acc_dout, u_dut.freq_dout);
        // RST 释放后逐周期看 hc174/carry/adder 状态
        begin : rst_release_trace
            integer k;
            for (k = 0; k < 16; k = k + 1) begin
                @(posedge SPFM_CLK);
                #1;
                $display("  AfterRST k=%0d hcnt=%02X step=%0d sub=%0d acc_we_n=%b clk174=%b rom3m=%02X acc=%b freq=%b adder_s=%b c4=%b carry=%06b ram_din=%b u6_we=%b u6_cs=%b ram_addr=%01X u6[0..4]=%b%b%b%b%b",
                    k, u_dut.hcnt_r, u_dut.tdm_step, u_dut.sub_cyc,
                    u_dut.rom3m_acc_we_n, u_dut.clk174, u_dut.rom3m_data,
                    u_dut.acc_dout, u_dut.freq_dout,
                    u_dut.adder_s, u_dut.adder_c4, u_dut.carry_chain,
                    u_dut.ram_din_inv, u_dut.u6_we_n, u_dut.u6_cs_n, u_dut.ram_addr,
                    u_dut.u_u6.mem[0],u_dut.u_u6.mem[1],u_dut.u_u6.mem[2],
                    u_dut.u_u6.mem[3],u_dut.u_u6.mem[4]);
            end
        end

        // 写 voice 1 频率 (50h-54h) - A4 = 440Hz, step = 0x12C6
        // 用 16-bit 简化, 写低 4 个 nibble
        $display("Writing Voice 1 frequency = 0x12C6 (A4=440Hz)");
        spfm_write(8'h50, 8'h6);  // nibble 0
        spfm_write(8'h51, 8'hC);  // nibble 1
        spfm_write(8'h52, 8'h2);  // nibble 2
        spfm_write(8'h53, 8'h1);  // nibble 3
        spfm_write(8'h54, 8'h0);  // nibble 4

        // 写 voice 1 音量 = 15 (最大)
        $display("Writing Voice 1 volume = 15");
        spfm_write(8'h55, 8'hF);

        // 写 voice 1 波形 = 0 (sine)
        $display("Writing Voice 1 waveform = 0 (sine)");
        spfm_write(8'h45, 8'h0);

        // Setup 完成后立即看 carry (before internal state dump)
        $display("Setup complete, carry=%06b hcnt=%02X", u_dut.carry_chain, u_dut.hcnt_r);

        // 调试: 检查内部状态
        $display("");
        $display("=== Internal State After Setup ===");
        $display("reg_addr = 0x%02X", u_dut.u_spfm.reg_addr);
        $display("reg_data = 0x%02X", u_dut.u_spfm.reg_data);
        $display("hcnt = 0x%02X tdm_step=%0d sub=%0d (time=%0t)", u_dut.hcnt_r, u_dut.tdm_step, u_dut.sub_cyc, $time);
        $display("acc_dout = 0x%01X (u6_do_inv=%b)", u_dut.acc_dout, u_dut.u6_do_inv);
        $display("freq_dout = 0x%01X (u7_do_inv=%b)", u_dut.freq_dout, u_dut.u7_do_inv);
        $display("ram_addr = 0x%01X", u_dut.ram_addr);
        $display("U6 mem[5]=%b U7 mem[5]=%b", u_dut.u_u6.mem[5], u_dut.u_u7.mem[5]);
        $display("carry_chain (1L) = 0x%02X", u_dut.carry_chain);
        $display("adder_s = 0x%01X  adder_c4=%b", u_dut.adder_s, u_dut.adder_c4);
        $display("rom3m: acc_we_n=%b clr_n=%b cp273=%b clk174=%b",
                 u_dut.rom3m_acc_we_n, u_dut.rom3m_clr_n, u_dut.cp273, u_dut.clk174);
        $display("rom3m_data = 0x%02X", u_dut.rom3m_data);
        $display("u_u3.mem[0..F] = %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",
                 u_dut.u_u3.mem[0], u_dut.u_u3.mem[1], u_dut.u_u3.mem[2], u_dut.u_u3.mem[3],
                 u_dut.u_u3.mem[4], u_dut.u_u3.mem[5], u_dut.u_u3.mem[6], u_dut.u_u3.mem[7],
                 u_dut.u_u3.mem[8], u_dut.u_u3.mem[9], u_dut.u_u3.mem[10], u_dut.u_u3.mem[11],
                 u_dut.u_u3.mem[12], u_dut.u_u3.mem[13], u_dut.u_u3.mem[14], u_dut.u_u3.mem[15]);
        $display("rom1m_data = 0x%02X", u_dut.rom1m_data);
        $display("u11_q (273 out) = 0x%02X", u_dut.u11_q);

        // Dump RAM 内容
        $display("");
        $display("=== U6 (acc RAM) Content ===");
        for (i = 0; i < 16; i = i + 1)
            $display("  U6[%0d] = %b", i, u_dut.u_u6.mem[i]);
        $display("=== U7 (freq RAM) Content ===");
        for (i = 0; i < 16; i = i + 1)
            $display("  U7[%0d] = %b", i, u_dut.u_u7.mem[i]);
        $display("");

        $display("Setup complete, running 50000 cycles (~0.5 sec audio)...");
        nonzero_count = 0;

        // 跑前 200 周期看 DAC 模式
        $display("");
        $display("=== DAC pattern trace ===");
        for (i = 0; i < 200; i = i + 1) begin
            @(posedge SPFM_CLK);
            #1;
            if (i < 40 || (i % 32 == 0 && i < 200))
                $display("  i=%0d hcnt=%02X dac=%02X u11_q=%02X carry=%06b wave_sel=%03b phase_sel=%05b rom1m=%02X cp273=%b",
                    i, u_dut.hcnt_r, dac_out, u_dut.u11_q, u_dut.carry_chain,
                    u_dut.wave_sel, u_dut.phase_sel, u_dut.rom1m_data, u_dut.cp273);
        end

        // 追踪 3 个完整输出周期 (step 5)
        $display("");
        $display("=== Output step (step 5) trace ===");
        begin : output_step_trace
            integer k;
            for (k = 0; k < 500; k = k + 1) begin
                @(posedge SPFM_CLK);
                #0.1;
                if (u_dut.hcnt_r[5:2] == 4'd5 && u_dut.hcnt_r[1:0] == 2'd0) begin
                    $display("  hcnt=%02X step5_sub0: carry=%06b phase=%02d rom_addr=%02d rom1m=%02X dac=%02X cp273=%b clk174=%b",
                        u_dut.hcnt_r, u_dut.carry_chain, u_dut.phase_sel,
                        {u_dut.wave_sel, u_dut.phase_sel}, u_dut.rom1m_data, dac_out, u_dut.cp273, u_dut.clk174);
                end
                if (u_dut.cp273) begin
                    $display("  hcnt=%02X cp273_RISE: carry=%06b phase=%02d rom_addr=%02d rom1m=%02X dac=%02X",
                        u_dut.hcnt_r, u_dut.carry_chain, u_dut.phase_sel,
                        {u_dut.wave_sel, u_dut.phase_sel}, u_dut.rom1m_data, dac_out);
                end
            end
        end

        // 打开 CSV 输出
        fd = $fopen("wsg3_dac.csv", "w");
        if (fd == 0) begin
            $display("ERROR: cannot open wsg3_dac.csv");
            $finish;
        end

        // 跑 50000 个时钟周期, 采样 DAC 并写 CSV
        for (i = 0; i < 50000; i = i + 1) begin
            @(posedge SPFM_CLK);
            dac_sample = dac_out;
            // 跳过 X 态 (仿真启动阶段), 写 0 避免 csv2wav 解析失败
            if (^dac_sample === 1'bx)
                $fwrite(fd, "0\n");
            else
                $fwrite(fd, "%0d\n", dac_sample);
            if (dac_sample != 0)
                nonzero_count = nonzero_count + 1;
            // 前 32 周期打印内部状态 (诊断累加器是否真的累加)
            if (i < 32) begin
                $display("  Cyc %0d hcnt=%02X step=%0d sub=%0d acc=%b freq=%b adder_s=%b adder_c4=%b carry=%06b acc_we_n=%b clr_n=%b cp273=%b clk174=%b",
                    i, u_dut.hcnt_r, u_dut.tdm_step, u_dut.sub_cyc,
                    u_dut.acc_dout, u_dut.freq_dout,
                    u_dut.adder_s, u_dut.adder_c4, u_dut.carry_chain,
                    u_dut.rom3m_acc_we_n, u_dut.rom3m_clr_n, u_dut.cp273, u_dut.clk174);
            end
            // 每 5000 周期打印一次
            if (i % 5000 == 0)
                $display("  Cycle %0d: DAC = 0x%02X", i, dac_sample);
        end
        $fclose(fd);

        $display("");
        $display("=== Results ===");
        $display("Total cycles: 500");
        $display("Non-zero DAC samples: %0d", nonzero_count);

        if (nonzero_count > 0)
            $display("PASS: DAC has audio output");
        else
            $display("FAIL: DAC is silent (no audio output)");

        $display("=== Test Complete ===");
        $finish;
    end

endmodule
