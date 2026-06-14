// wt3_core_tb.v — WSG 完整数据通路验证 + sine wav 输出
// SPFM 写入 phase_acc + phase_step, 微码循环累加, wavetable ROM 查表, 273 输出 sine

`timescale 1ns/1ps

module wt3_core_tb;

    reg STEP_CLK, SPFM_CLK, SPFM_RST_n;
    reg [7:0] SPFM_D;
    reg SPFM_A0, SPFM_CS_n, SPFM_WR_n, SPFM_RD_n;

    wire [7:0] reg_a_q;
    wire [7:0] reg_b_q;
    wire [7:0] adder_s;
    wire [7:0] dac_out;

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
        .adder_s(adder_s),
        .dac_out(dac_out)
    );

    initial STEP_CLK = 0;
    always #162.5 STEP_CLK = ~STEP_CLK;  // ~3.08 MHz, 96kHz × 32 步

    initial SPFM_CLK = 0;
    always #50 SPFM_CLK = ~SPFM_CLK;  // 10 MHz

    integer pass, fail;
    integer i, sample_count;
    integer fd;

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

        #1000;
        SPFM_RST_n = 1;
        #1000;

        $display("=== WSG Core Test (wavetable + 273 output) ===");

        // phase_acc=0x00, phase_step=0x08 → 每 96kHz 周期相位增 8, sine 周期 = 256/8 = 32 样本
        // 频率 = 96000 / 32 = 3000 Hz
        $display("SPFM write phase_acc=0x00, phase_step=0x08...");
        spfm_write(8'h00, 8'h00);
        spfm_write(8'h01, 8'h08);

        // 验证 1 个完整周期后输出
        #11000;
        $display("After 1 cycle:");
        $display("  reg_a_q = 0x%02X", reg_a_q);
        $display("  reg_b_q = 0x%02X", reg_b_q);
        $display("  adder_s = 0x%02X", adder_s);
        $display("  dac_out = 0x%02X (sine[reg_a])", dac_out);

        if (reg_b_q === 8'h08) begin $display("  reg_b=0x08 OK"); pass = pass + 1;
        end else begin $display("  reg_b=0x%02X FAIL", reg_b_q); fail = fail + 1; end

        // 生成 wav 文件: 采 50000 个样本 (≈0.52s, 3000Hz×1560 周期)
        fd = $fopen("wt3_sine.csv", "w");
        sample_count = 0;
        for (i = 0; i < 50000; i = i + 1) begin
            // 等 step 5 (latch_dac_clk 上升沿) 后采样 dac_out
            @(posedge u_dut.latch_dac_clk);
            #100;  // 等 273 tpd
            $fdisplay(fd, "%0d", dac_out);
            sample_count = sample_count + 1;
        end
        $fclose(fd);

        $display("Generated wt3_sine.csv with %0d samples", sample_count);
        $display("=== Result: %0d pass, %0d fail ===", pass, fail);
        if (fail == 0) $display("PASS"); else $display("FAIL");

        $finish;
    end

endmodule
