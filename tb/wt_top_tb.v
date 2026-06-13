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

    task wait_sample;
        integer i;
        begin
            for (i = 0; i < 32; i = i + 1)
                @(posedge STEP_CLK);
        end
    endtask

    initial begin
        SPFM_RST_n = 0; SPFM_CS_n = 1; SPFM_WR_n = 1;
        SPFM_RD_n = 1; SPFM_A0 = 0; SPFM_D = 8'h00;

        #5000;
        SPFM_RST_n = 1;
        #5000;

        $display("=== wt_top Testbench ===");

        // 96kHz 采样率: step = freq * 2^20 / 96000
        // A4 440Hz → step = 4806 = 0x12C6

        write_voice(4'd0, 20'h12C6, 3'd0, 4'd15);  // A4 sine vol=15, 单通道
        write_voice(4'd1, 20'h0000, 3'd0, 4'd0);
        write_voice(4'd2, 20'h0000, 3'd0, 4'd0);

        // 等几个 cycle 让 phase 稳定
        repeat (100) wait_sample();

        f_csv = $fopen("wt_top_output.csv", "w");
        $fwrite(f_csv, "sample,dac\n");
        $display("--- Collecting 5000 samples ---");

        for (sample_count = 0; sample_count < 5000; sample_count = sample_count + 1) begin
            wait_sample();
            $fwrite(f_csv, "%0d,%0d\n", sample_count, dac_out);
        end

        $fclose(f_csv);
        $display("--- Done ---");
        $finish;
    end

    initial begin
        $dumpfile("wt_top_tb.vcd");
        $dumpvars(0, wt_top_tb);
    end

endmodule
