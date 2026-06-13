// wt_top_tb.v — wt_top 顶层模块测试
// 3.072MHz → 32 步 → 96kHz 采样率 (与 WSG 原版一致)

`timescale 1ns/1ps

module wt_top_tb;

    reg  STEP_CLK;
    reg  SPFM_CLK;
    reg  SPFM_RST_n;
    reg  [7:0] SPFM_D;
    reg  SPFM_A0;
    reg  SPFM_CS_n;
    reg  SPFM_WR_n;
    reg  SPFM_RD_n;

    wire [7:0] dac_out;

    wt_top u_dut (
        .STEP_CLK(STEP_CLK),
        .SPFM_CLK(SPFM_CLK),
        .SPFM_RST_n(SPFM_RST_n),
        .SPFM_D(SPFM_D),
        .SPFM_A0(SPFM_A0),
        .SPFM_CS_n(SPFM_CS_n),
        .SPFM_WR_n(SPFM_WR_n),
        .SPFM_RD_n(SPFM_RD_n),
        .dac_out(dac_out)
    );

    // STEP_CLK: 3.072MHz → 周期 ~325.5ns
    initial STEP_CLK = 0;
    always #162.75 STEP_CLK = ~STEP_CLK;

    // SPFM_CLK: 8MHz → 周期 125ns
    initial SPFM_CLK = 0;
    always #62.5 SPFM_CLK = ~SPFM_CLK;

    task spfm_write;
        input [7:0] addr;
        input [7:0] data;
        begin
            SPFM_RST_n = 1; SPFM_CS_n = 0; SPFM_WR_n = 0;
            SPFM_A0 = 0; SPFM_D = addr;
            #2000;
            SPFM_CS_n = 1; SPFM_WR_n = 1;
            #2000;
            SPFM_CS_n = 0; SPFM_WR_n = 0;
            SPFM_A0 = 1; SPFM_D = data;
            #2000;
            SPFM_CS_n = 1; SPFM_WR_n = 1;
            #2000;
        end
    endtask

    task write_voice;
        input [3:0] voice;
        input [19:0] freq;
        input [2:0]  wave;
        input [3:0]  vol;
        integer i;
        reg [7:0] base;
        begin
            base = voice * 8;
            for (i = 0; i < 5; i = i + 1)
                spfm_write(base + i, freq[i*4 +: 4]);
            spfm_write(base + 5, {5'b0, wave});
            spfm_write(base + 6, {4'b0, vol});
        end
    endtask

    integer f_csv;
    integer sample_count;
    reg [7:0] sv0, sv1, sv2;

    // TDM 采样: 每个 32-step 周期采样 3 个 voice (step 7/15/23 lookup)
    // 输出 v0,v1,v2 到 CSV, 后续软件混音
    task sample_voices;
        output [7:0] v0;
        output [7:0] v1;
        output [7:0] v2;
        begin
            // voice 0 lookup (step==7 negedge 锁存)
            @(negedge STEP_CLK);
            while (u_dut.step !== 5'd7) @(negedge STEP_CLK);
            #1; v0 = dac_out;
            // voice 1 lookup (step==15)
            @(negedge STEP_CLK);
            while (u_dut.step !== 5'd15) @(negedge STEP_CLK);
            #1; v1 = dac_out;
            // voice 2 lookup (step==23)
            @(negedge STEP_CLK);
            while (u_dut.step !== 5'd23) @(negedge STEP_CLK);
            #1; v2 = dac_out;
        end
    endtask

    initial begin
        SPFM_RST_n = 0; SPFM_CS_n = 1; SPFM_WR_n = 1;
        SPFM_RD_n = 1; SPFM_A0 = 0; SPFM_D = 8'h00;

        #5000;
        SPFM_RST_n = 1;
        #5000;

        $display("=== wt_top Testbench ===");

        // 96kHz 采样率: step = freq * 2^19 / 96000
        // C4 261.63Hz → 0x00595, E4 329.63Hz → 0x00708, G4 392.00Hz → 0x0085D
        // C 大三和弦 (C/E/G), sine 波, vol=12

        write_voice(4'd0, 20'h00595, 3'd0, 4'd12);  // C4 sine
        write_voice(4'd1, 20'h00708, 3'd0, 4'd12);  // E4 sine
        write_voice(4'd2, 20'h0085D, 3'd0, 4'd12);  // G4 sine

        // 等几个 cycle 让 phase 稳定
        repeat (100) sample_voices(sv0, sv1, sv2);

        f_csv = $fopen("wt_top_output.csv", "w");
        $fwrite(f_csv, "sample,v0,v1,v2\n");
        $display("--- Collecting 50000 samples (C-E-G chord) ---");

        for (sample_count = 0; sample_count < 50000; sample_count = sample_count + 1) begin
            sample_voices(sv0, sv1, sv2);
            $fwrite(f_csv, "%0d,%0d,%0d,%0d\n", sample_count, sv0, sv1, sv2);
        end

        $fclose(f_csv);
        $display("--- Done ---");
        $finish;
    end

    initial begin
        // $dumpfile("wt_top_tb.vcd");
        // $dumpvars(0, wt_top_tb);
    end

endmodule
