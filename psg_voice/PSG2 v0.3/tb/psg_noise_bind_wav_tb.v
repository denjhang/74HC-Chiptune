// psg_noise_bind_wav_tb.v — 绑定模式白噪 WAV (噪音跟方波音高)
//
// 模拟方波通道产生 C3-C7 的 square_tc, 绑定模式下 LFSR 跟随。
// 每个音 0.5 秒, freq_sel=÷2 (LFSR 时钟 = square_tc/2)。
// 主时钟 64kHz, 采样率 64kHz。

`timescale 1ns/1ps

module psg_noise_bind_wav_tb;

    reg clk = 0;
    localparam CLK_HZ = 64000;
    localparam CLK_PERIOD = 1_000_000_000 / CLK_HZ;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg        rst_n = 0;
    reg        A1 = 0;
    reg  [7:0] data = 0;
    reg        square_tc = 0;
    wire [7:0] audio_out;

    psg_noise_v03 u_dut (
        .clk(clk), .rst_n(rst_n),
        .A1(A1), .data(data),
        .square_tc(square_tc),
        .audio_out(audio_out)
    );

    // ===== 模拟方波通道 TC =====
    // 方波 HC161 从 period 计数到 0xFF, 计满 (256-period) 步 TC 触发重装。
    // 所以 TC 周期 = (256-period) 个 clk, 频率 = 64kHz/(256-period)。
    reg [15:0] tc_cnt = 0;
    reg [15:0] tc_steps;   // 当前音的计数步数 = 256-period
    always @(posedge clk) begin
        if (!rst_n) begin
            tc_cnt <= 0;
            square_tc <= 0;
        end else begin
            if (tc_cnt >= tc_steps - 1) begin
                square_tc <= 1;   // TC 脉冲 (1 个 clk 宽)
                tc_cnt <= 0;
            end else begin
                square_tc <= 0;
                tc_cnt <= tc_cnt + 1;
            end
        end
    end

    task write_ctrl;
        input [7:0] c;
        begin
            data = c; #200;
            A1 = 1; #500;
            A1 = 0; #200;
        end
    endtask

    integer wav_fp, smp_idx, ret;

    task wav_open;
        input [8*32-1:0] fname;
        begin
            wav_fp = $fopen(fname, "wb");
            $fwrite(wav_fp, "RIFF");
            $fwrite(wav_fp, "%c%c%c%c", 0,0,0,0);
            $fwrite(wav_fp, "WAVE");
            $fwrite(wav_fp, "fmt ");
            $fwrite(wav_fp, "%c%c%c%c", 16,0,0,0);
            $fwrite(wav_fp, "%c%c", 1,0);
            $fwrite(wav_fp, "%c%c", 1,0);
            $fwrite(wav_fp, "%c%c%c%c", 8'h00,8'hFA,8'h00,8'h00);
            $fwrite(wav_fp, "%c%c%c%c", 8'h00,8'hF4,8'h01,8'h00);
            $fwrite(wav_fp, "%c%c", 2,0);
            $fwrite(wav_fp, "%c%c", 16,0);
            $fwrite(wav_fp, "data");
            $fwrite(wav_fp, "%c%c%c%c", 0,0,0,0);
            smp_idx = 0;
        end
    endtask

    task wav_smp;
        input [7:0] a;
        integer s;
        begin
            s = (a == 0) ? -16000 : 16000;
            $fwrite(wav_fp, "%c%c", s[7:0], s[15:8]);
            smp_idx = smp_idx + 1;
        end
    endtask

    task wav_close;
        integer file_size, data_size;
        begin
            data_size = smp_idx * 2;
            file_size = 36 + data_size;
            ret = $fseek(wav_fp, 4, 0);
            $fwrite(wav_fp, "%c%c%c%c", file_size[7:0],file_size[15:8],file_size[23:16],file_size[31:24]);
            ret = $fseek(wav_fp, 40, 0);
            $fwrite(wav_fp, "%c%c%c%c", data_size[7:0],data_size[15:8],data_size[23:16],data_size[31:24]);
            $fclose(wav_fp);
        end
    endtask

    localparam SMP = 32000;   // 0.5s
    integer i;

    // 生成一段: 设 period, 内部算 tc_steps=256-period, 写控制字 (bind=1), 采样
    task gen_bind_clip;
        input [15:0] period;       // 方波 period
        input [8*32-1:0] fname;
        begin
            tc_steps = 16'd256 - period;   // 计数步数 = 256-period
            wav_open(fname);
            write_ctrl(8'h4F);   // vol=15(bit0-3), bind=1(bit6), freq=÷2(绑定直通无效)
            for (i = 0; i < SMP; i = i + 1) begin
                @(posedge clk);
                #1;
                wav_smp(audio_out);
            end
            wav_close;
            $display("  OK period=%0d steps=%0d (%0s)", period, tc_steps, fname);
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (30) @(posedge clk);

        $display("=== 绑定模式白噪 WAV (噪音跟方波音高, freq=÷2) ===");

        // C3-C7: period 据公式 256 - 64000/(2*f)
        gen_bind_clip(16'd11,  "bind_C3.wav");    // 131 Hz
        gen_bind_clip(16'd133, "bind_C4.wav");    // 262 Hz
        gen_bind_clip(16'd194, "bind_C5.wav");    // 523 Hz
        gen_bind_clip(16'd225, "bind_C6.wav");    // 1047 Hz
        gen_bind_clip(16'd240, "bind_C7.wav");    // 2093 Hz

        $display("=== 完成 ===");
        $finish;
    end

    initial begin
        #5_000_000_000;
        $display("ERROR: 超时");
        $finish;
    end

endmodule
