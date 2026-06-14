// wt3_piano_tb.v — 钢琴式衰减包络演示
// CPU 软件包络: 按时间表更新 volume 寄存器
//   1) attack 瞬间到满档
//   2) 缓慢指数衰减
//   3) 衰减结束静音
//
// 采样 1.5s × 96kHz = 144000 样本

`timescale 1ns/1ps

module wt3_piano_tb;

    reg STEP_CLK, SPFM_CLK, SPFM_RST_n;
    reg [7:0] SPFM_D;
    reg SPFM_A0, SPFM_CS_n, SPFM_WR_n, SPFM_RD_n;

    wire [7:0] reg_a_q;
    wire [7:0] reg_b_q;
    wire [7:0] reg_c_q;
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
        .reg_c_q(reg_c_q),
        .adder_s(adder_s),
        .dac_out(dac_out)
    );

    initial STEP_CLK = 0;
    always #162.5 STEP_CLK = ~STEP_CLK;  // ~3.08 MHz, 96kHz × 32 步

    initial SPFM_CLK = 0;
    always #50 SPFM_CLK = ~SPFM_CLK;  // 10 MHz

    integer fd;
    integer sample_count;
    integer i;

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

    // 钢琴式衰减曲线: 输入时间(ms), 输出音量(0-15)
    // 实际硬件里这是 CPU 写 volume 寄存器的时刻表
    function [7:0] piano_envelope;
        input integer t_ms;
        integer vol;
        begin
            if (t_ms < 5)        vol = 15;       // attack (0-5ms 满档)
            else if (t_ms < 10)  vol = 15;       // 短暂保持
            else if (t_ms < 30)  vol = 13;       // 快速 decay 开始
            else if (t_ms < 60)  vol = 11;
            else if (t_ms < 100) vol = 9;
            else if (t_ms < 200) vol = 7;
            else if (t_ms < 350) vol = 5;
            else if (t_ms < 600) vol = 3;
            else if (t_ms < 1000) vol = 2;
            else if (t_ms < 1500) vol = 1;
            else vol = 0;                        // 静音
            piano_envelope = vol[7:0];
        end
    endfunction

    real t_ms;        // 当前时间(ms)
    real sample_ms;   // 每采样周期(ms)
    reg [7:0] cur_vol;
    reg [7:0] new_vol;

    initial begin
        SPFM_RST_n = 0; SPFM_CS_n = 1; SPFM_WR_n = 1;
        SPFM_RD_n = 1; SPFM_A0 = 0; SPFM_D = 8'h00;

        #1000;
        SPFM_RST_n = 1;
        #1000;

        $display("=== Piano Envelope Demo ===");
        $display("Press key: phase_step=0x08 (3000Hz), vol=15 (满档)");
        $display("Then CPU decays vol over time...");

        // 设置频率
        spfm_write(8'h00, 8'h00);   // phase_acc = 0
        spfm_write(8'h01, 8'h08);   // phase_step = 0x08 (3000Hz)

        // 初始音量满档
        spfm_write(8'h02, 8'h0F);

        sample_ms = 1000.0 / 96000.0;  // 每样本 ≈ 0.01042 ms

        fd = $fopen("wt3_piano.csv", "w");
        sample_count = 0;
        cur_vol = 8'h0F;

        // 采集 150000 样本 (1.5625s)
        for (i = 0; i < 150000; i = i + 1) begin
            @(posedge u_dut.latch_dac_clk);
            #100;

            // CPU 端按时间表更新 volume
            t_ms = i * sample_ms;
            new_vol = piano_envelope(t_ms);

            // 只在 vol 变化时才写 (减少 SPFM 总线活动)
            if (new_vol !== cur_vol) begin
                cur_vol = new_vol;
                // 在 latch_dac_clk 上升沿之后写 (不打断微码循环)
                spfm_write(8'h02, cur_vol);
            end

            $fdisplay(fd, "%0d", dac_out);
            sample_count = sample_count + 1;
        end
        $fclose(fd);

        $display("Generated wt3_piano.csv with %0d samples (%0.3fs)",
                 sample_count, sample_count / 96000.0);
        $display("=== Done ===");

        $finish;
    end

endmodule
