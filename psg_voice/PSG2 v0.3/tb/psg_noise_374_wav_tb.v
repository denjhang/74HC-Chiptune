// psg_noise_374_wav_tb.v — HC374 版 LFSR 噪音 WAV 试听
//
// 生成 64kHz 采样 WAV, 试听 4 挡频率 + 绑定模式.

`timescale 1ns/1ps

module psg_noise_374_wav_tb;
    reg        clk = 0;
    reg        A1 = 0;
    reg  [7:0] data = 0;
    reg        square_tc = 0;
    wire [7:0] audio;

    psg_noise_374_v03 u_dut (
        .clk(clk), .A1(A1), .data(data),
        .square_tc(square_tc), .audio_out(audio)
    );

    always #7812.5 clk = ~clk;   // 64kHz

    // 模拟方波 TC (period=233, C7 附近, 高频用于绑定测试)
    reg [7:0] tc_cnt = 0;
    always @(posedge clk) begin
        tc_cnt <= tc_cnt + 8'd1;
        if (tc_cnt >= 233) begin
            tc_cnt <= 0;
            square_tc <= ~square_tc;
        end
    end

    task write_ctrl(input [7:0] val);
        begin
            data = val;
            #100;
            A1 = 1; #100;
            A1 = 0; #100;
        end
    endtask

    // WAV 输出 (64kHz, 16-bit mono)
    integer fd;
    integer i;
    real sample_val;
    reg [15:0] sample;
    integer SAMPLES_PER_SEC = 64000;
    integer DURATION_SEC = 2;   // 每挡 2 秒

    task wav_header;
        begin
            // RIFF header
            fd = $fopen("noise374_test.wav", "wb");
            $fwrite(fd, "RIFF");
            $fwrite(fd, "%c%c%c%c", 36 + 0, 0, 0, 0);   // 占位, 最后改
            $fwrite(fd, "WAVE");
            // fmt chunk
            $fwrite(fd, "fmt ");
            $fwrite(fd, "%c%c%c%c", 16, 0, 0, 0);   // chunk size
            $fwrite(fd, "%c%c", 1, 0);               // PCM
            $fwrite(fd, "%c%c", 1, 0);               // mono
            $fwrite(fd, "%c%c%c%c", 64, 0, 0, 0);    // 64000 Hz? 实际 15625? 见下
            // (采样率用 64kHz = 0xFA00 → 但 $fwrite 字节序: 0x00 0xFA 0x00 0x00)
        end
    endtask

    real clk_period_ns = 15625.0;   // 64kHz 周期
    integer samples_to_write;
    integer written = 0;
    integer data_size;

    initial begin
        // 4 挡频率各 2 秒 + 绑定 2 秒, 共 10 秒
        samples_to_write = SAMPLES_PER_SEC * 10;
        data_size = samples_to_write * 2;

        fd = $fopen("noise374_test.wav", "wb");
        // 简化: 用 $fwrite 写字节
        // RIFF
        $fwrite(fd, "RIFF");
        $fwrite(fd, "%c%c%c%c", (36+44+data_size) & 8'hff,
                                ((36+44+data_size)>>8) & 8'hff,
                                ((36+44+data_size)>>16) & 8'hff,
                                ((36+44+data_size)>>24) & 8'hff);
        $fwrite(fd, "WAVE");
        // fmt
        $fwrite(fd, "fmt ");
        $fwrite(fd, "%c%c%c%c", 16, 0, 0, 0);
        $fwrite(fd, "%c%c", 1, 0);                  // PCM
        $fwrite(fd, "%c%c", 1, 0);                  // 1 ch
        $fwrite(fd, "%c%c%c%c", 0, 250, 0, 0);      // 64000 = 0xFA00
        $fwrite(fd, "%c%c%c%c", 0, 250, 0, 0);      // byte rate = 64000*2
        $fwrite(fd, "%c%c", 2, 0);                  // block align
        $fwrite(fd, "%c%c", 16, 0);                 // 16 bit
        // data
        $fwrite(fd, "data");
        $fwrite(fd, "%c%c%c%c", data_size & 8'hff,
                                (data_size>>8) & 8'hff,
                                (data_size>>16) & 8'hff,
                                (data_size>>24) & 8'hff);

        // 段 1: ÷2 (vol=15, freq=00, bind=0) = 0x0F
        write_ctrl(8'h0F);
        for (i = 0; i < SAMPLES_PER_SEC * 2; i = i + 1) begin
            #15625;
            sample = {audio, audio};   // 8-bit 扩展到 16-bit (重复)
            $fwrite(fd, "%c%c", sample[7:0], sample[15:8]);
        end
        $display("÷2 写完");

        // 段 2: ÷4 (vol=15, freq=01) = 0x1F
        write_ctrl(8'h1F);
        for (i = 0; i < SAMPLES_PER_SEC * 2; i = i + 1) begin
            #15625;
            sample = {audio, audio};
            $fwrite(fd, "%c%c", sample[7:0], sample[15:8]);
        end
        $display("÷4 写完");

        // 段 3: ÷8 (vol=15, freq=10) = 0x2F
        write_ctrl(8'h2F);
        for (i = 0; i < SAMPLES_PER_SEC * 2; i = i + 1) begin
            #15625;
            sample = {audio, audio};
            $fwrite(fd, "%c%c", sample[7:0], sample[15:8]);
        end
        $display("÷8 写完");

        // 段 4: ÷16 (vol=15, freq=11) = 0x3F
        write_ctrl(8'h3F);
        for (i = 0; i < SAMPLES_PER_SEC * 2; i = i + 1) begin
            #15625;
            sample = {audio, audio};
            $fwrite(fd, "%c%c", sample[7:0], sample[15:8]);
        end
        $display("÷16 写完");

        // 段 5: 绑定 (vol=15, freq=00, bind=1) = 0x4F
        write_ctrl(8'h4F);
        for (i = 0; i < SAMPLES_PER_SEC * 2; i = i + 1) begin
            #15625;
            sample = {audio, audio};
            $fwrite(fd, "%c%c", sample[7:0], sample[15:8]);
        end
        $display("绑定写完");

        $fclose(fd);
        $display("=== noise374_test.wav 完成 (10秒) ===");
        $display("  段1: ÷2 (0:00-0:02)");
        $display("  段2: ÷4 (0:02-0:04)");
        $display("  段3: ÷8 (0:04-0:06)");
        $display("  段4: ÷16(0:06-0:08)");
        $display("  段5: 绑定(0:08-0:10)");
        $finish;
    end

endmodule
