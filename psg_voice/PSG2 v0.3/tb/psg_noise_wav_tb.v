// psg_noise_wav_tb.v — 生成 LFSR 噪音 WAV 试听文件
//
// 主时钟 64kHz, 每个 64kHz 周期采样一次 audio_out。
// 输出多组 WAV: 白噪/周期 × 4 个频率挡 (÷2/÷4/÷8/÷16)。
// 采样率 64kHz, 16-bit PCM, 单声道。短文件名 (输出到 tb 目录, 仿真后改名)。

`timescale 1ns/1ps

module psg_noise_wav_tb;

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

    task write_ctrl;
        input [7:0] c;
        begin
            data = c; #200;
            A1 = 1; #500;
            A1 = 0; #200;
        end
    endtask

    integer wav_fp;
    integer smp_idx;
    integer ret;

    // 写一个采样 (audio_out 0→-16000, 240→+16000)
    task wav_open;
        input [8*32-1:0] fname;   // 32 字节够短文件名
        integer s;
        begin
            wav_fp = $fopen(fname, "wb");
            // RIFF
            $fwrite(wav_fp, "RIFF");
            $fwrite(wav_fp, "%c%c%c%c", 0,0,0,0);
            $fwrite(wav_fp, "WAVE");
            // fmt
            $fwrite(wav_fp, "fmt ");
            $fwrite(wav_fp, "%c%c%c%c", 16,0,0,0);
            $fwrite(wav_fp, "%c%c", 1,0);                       // PCM
            $fwrite(wav_fp, "%c%c", 1,0);                       // mono
            $fwrite(wav_fp, "%c%c%c%c", 8'h00,8'hFA,8'h00,8'h00); // 64000 Hz
            $fwrite(wav_fp, "%c%c%c%c", 8'h00,8'hF4,8'h01,8'h00); // 128000 byte/s
            $fwrite(wav_fp, "%c%c", 2,0);                       // block align
            $fwrite(wav_fp, "%c%c", 16,0);                      // 16-bit
            // data
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
        integer file_size;
        integer data_size;
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

    // 每段 0.5 秒 = 32000 采样 (够试听周期噪音断续节奏)
    localparam SMP = 32000;
    integer i;

    task gen_clip;
        input [7:0] ctrl;
        input [8*32-1:0] fname;
        begin
            wav_open(fname);
            write_ctrl(ctrl);
            for (i = 0; i < SMP; i = i + 1) begin
                @(posedge clk);
                #1;
                wav_smp(audio_out);
            end
            wav_close;
            $display("  OK %0d 采样", SMP);
        end
    endtask

    // 控制字 {vol[7:4], bind[3], ntype[2], freq[1:0]}
    localparam V15 = 8'h0F;   // vol=15 在 bit0-3

    initial begin
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (30) @(posedge clk);   // RST 灌种子

        $display("=== LFSR 噪音 WAV (64kHz 主时钟, 64kHz 采样) ===");

        $display("[白噪 4 挡频率]");
        gen_clip(V15 | 8'h00, "w_white_d2.wav");   // freq=÷2 (bit4-5=00)
        gen_clip(V15 | 8'h10, "w_white_d4.wav");   // freq=÷4 (bit4-5=01)
        gen_clip(V15 | 8'h20, "w_white_d8.wav");   // freq=÷8 (bit4-5=10)
        gen_clip(V15 | 8'h30, "w_white_d16.wav");  // freq=÷16(bit4-5=11)

        // 周期噪音已砍 (试听验证不可用), 只保留白噪 4 挡

        $display("=== 完成 ===");
        $finish;
    end

    initial begin
        #8_000_000_000;   // 8s 超时 (8段×0.5s=4s仿真 + 余量)
        $display("ERROR: 超时");
        $finish;
    end

endmodule
