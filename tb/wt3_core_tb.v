// wt3_core_tb.v — WSG v1.3 4 通道 TDM 完整数据通路验证
//
// 每通道 RAM 地址: {channel, sub_addr}
//   ch0: RAM[0]=phase_acc, RAM[1]=phase_step, RAM[2]=volume, RAM[3]=reserved
//   ch1: RAM[4..6]
//   ch2: RAM[8..10]
//   ch3: RAM[12..14]
//
// 4 通道同时不同频率, 都满档音量
// TDM: 4 通道在 64 step 内分时刷新, DAC 输出在通道间快速切换

`timescale 1ns/1ps

module wt3_core_tb;

    reg STEP_CLK, SPFM_CLK, SPFM_RST_n;
    reg [7:0] SPFM_D;
    reg SPFM_A0, SPFM_CS_n, SPFM_WR_n, SPFM_RD_n;

    wire [7:0] reg_a_q;
    wire [7:0] reg_b_q;
    wire [7:0] reg_c_q;
    wire [7:0] adder_s;
    wire [7:0] dac_out;
    wire [2:0] cur_channel;
    wire [2:0] cur_substep;

    wt3_core u_dut (
        .STEP_CLK(STEP_CLK),
        .SPFM_CLK(SPFM_CLK),
        .SPFM_RST_n(SPFM_RST_n),
        .SPFM_D(SPFM_D),
        .SPFM_A0(SPFM_A0),
        .SPFM_CS_n(SPFM_CS_n),
        .SPFM_WR_n(SPFM_WR_n),
        .SPFM_RD_n(SPFM_RD_n),
        .reg_a_q(reg_a_q),
        .reg_b_q(reg_b_q),
        .reg_c_q(reg_c_q),
        .adder_s(adder_s),
        .dac_out(dac_out),
        .cur_channel(cur_channel),
        .cur_substep(cur_substep)
    );

    initial STEP_CLK = 0;
    always #162.5 STEP_CLK = ~STEP_CLK;  // ~3.08 MHz, 48kHz × 64 步

    initial SPFM_CLK = 0;
    always #50 SPFM_CLK = ~SPFM_CLK;  // 10 MHz

    integer pass, fail;
    integer i, ch, sample_count;
    integer fd;
    reg [7:0] observed_max;
    reg [7:0] acc;
    reg [7:0] ch_phase_step [0:3];

    task spfm_write;
        input [7:0] addr;
        input [7:0] data;
    begin
        @(negedge SPFM_CLK);
        SPFM_CS_n = 0; SPFM_WR_n = 0; SPFM_A0 = 0; SPFM_D = addr;
        repeat(5) @(posedge SPFM_CLK);
        SPFM_CS_n = 1; SPFM_WR_n = 1;
        repeat(5) @(posedge SPFM_CLK);
        @(negedge SPFM_CLK);
        SPFM_CS_n = 0; SPFM_WR_n = 0; SPFM_A0 = 1; SPFM_D = data;
        repeat(5) @(posedge SPFM_CLK);
        SPFM_CS_n = 1; SPFM_WR_n = 1;
        repeat(5) @(posedge SPFM_CLK);
    end
    endtask

    initial begin
        SPFM_RST_n = 0; SPFM_CS_n = 1; SPFM_WR_n = 1;
        SPFM_RD_n = 1; SPFM_A0 = 0; SPFM_D = 8'h00;
        pass = 0; fail = 0;

        // 4 通道不同频率 (3000, 4000, 5000, 6000 Hz @ 48kHz)
        // freq = phase_step × 48000 / 256 = phase_step × 187.5
        ch_phase_step[0] = 8'd16;  // 3000 Hz
        ch_phase_step[1] = 8'd21;  // ≈3937 Hz
        ch_phase_step[2] = 8'd27;  // ≈5062 Hz
        ch_phase_step[3] = 8'd32;  // 6000 Hz

        #1000;
        SPFM_RST_n = 1;
        #1000;

        $display("=== WSG v1.3 4-channel TDM Test ===");

        // 写每个通道的 phase_step (addr = ch*4+1) 和 volume=0x0F (addr = ch*4+2)
        for (ch = 0; ch < 4; ch = ch + 1) begin
            spfm_write((ch*4+1), ch_phase_step[ch]);
            spfm_write((ch*4+2), 8'h0F);
        end

        // RAM 内容转储
        $display("RAM contents after write:");
        for (ch = 0; ch < 4; ch = ch + 1) begin
            $display("  ch%0d: phase_acc=0x%02X phase_step=0x%02X volume=0x%02X",
                ch,
                u_dut.u_ram.mem[ch*4+0],
                u_dut.u_ram.mem[ch*4+1],
                u_dut.u_ram.mem[ch*4+2]);
        end

        // 等待 1 个完整 64-step 周期 (在 ch3.dac_clk 之后)
        // 在 ch3.step7 (step=55) 的 dac_clk 上升沿后, 所有 4 通道都已刷新一次
        @(posedge u_dut.latch_dac_clk);  // ch0.dac_clk (step 7)
        @(posedge u_dut.latch_dac_clk);  // ch1.dac_clk (step 23)
        @(posedge u_dut.latch_dac_clk);  // ch2.dac_clk (step 39)
        @(posedge u_dut.latch_dac_clk);  // ch3.dac_clk (step 55)
        #500;  // 等写回完成

        $display("After 1 cycle, phase_acc per channel:");
        for (ch = 0; ch < 4; ch = ch + 1) begin
            // phase_acc 应该是 phase_step 的整数倍 (累加若干次)
            // 因为 step 计数器在 SPFM 写参数时已经在跑, 各通道累加次数可能不同
            acc = u_dut.u_ram.mem[ch*4+0];
            if (acc != 0 && (acc % ch_phase_step[ch]) == 0) begin
                $display("  ch%0d: phase_acc=0x%02X (step=0x%02X, x%0d) OK",
                    ch, acc, ch_phase_step[ch], acc / ch_phase_step[ch]);
                pass = pass + 1;
            end else begin
                $display("  ch%0d: phase_acc=0x%02X (step=0x%02X, not multiple) FAIL",
                    ch, acc, ch_phase_step[ch]);
                fail = fail + 1;
            end
        end

        // 生成 wav: 50000 个 DAC 样本 (TDM 4 通道混合)
        // 每通道采样率 48kHz, 总样本率 192kHz, 50000 样本 ≈ 0.26s
        fd = $fopen("wt3_sine.csv", "w");
        sample_count = 0;
        observed_max = 0;
        for (i = 0; i < 50000; i = i + 1) begin
            @(posedge u_dut.latch_dac_clk);
            #100;  // 等 273 tpd
            $fdisplay(fd, "%0d", dac_out);
            if (dac_out > observed_max) observed_max = dac_out;
            sample_count = sample_count + 1;
        end
        $fclose(fd);

        // 满档音量: dac_out 最大应接近 0xFF
        if (observed_max >= 8'hF0) begin
            $display("  observed_max=0x%02X (>= 0xF0, 满档振幅 OK)", observed_max);
            pass = pass + 1;
        end else begin
            $display("  observed_max=0x%02X FAIL (满档应 >= 0xF0)", observed_max);
            fail = fail + 1;
        end

        $display("Generated wt3_sine.csv with %0d samples", sample_count);
        $display("=== Result: %0d pass, %0d fail ===", pass, fail);
        if (fail == 0) $display("PASS"); else $display("FAIL");

        $finish;
    end

endmodule
