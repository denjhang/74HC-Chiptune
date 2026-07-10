// fm6_note_tb.v — FM6 v0.7 单通道 FM 音符验证
//
// 验证:
//   1. NCO 累加频率正确 (phase_m/phase_c 步进)
//   2. conv_vol 查表输出正弦 (idx 周期性扫表)
//   3. 相位调制产生 FM 泛音 (carrier 被 mod_out 调制)
//   4. 输出 WAV 试听
//
// 测试条件:
//   - step_m / step_c 设成产生 ~440Hz (A4)
//   - env_level_m = 31 (满调制深度), env_level_c = 31 (满音量)
//   - fb = 0 (无反馈, 调制完全来自 OP1→OP2 相位)
//   - vol = 0 (最大音量, ym2413: out = carrier × (16-vol) )
//
// WAV 输出: 66.3kHz 采样, 8-bit unsigned, mono

`timescale 1ns/1ps

module fm6_note_tb;

    // ============================================================
    // 时钟和采样
    // ============================================================
    // 设计采样率 66.3kHz (14.318MHz / 216)
    // 仿真简化: samp_en 每 SIM_SAMPLES_PER_SAMP 个时钟拉高 1 次
    // 这里直接用 samp_en 做采样节拍, clk 只是载体
    reg clk = 0;
    always #5 clk = ~clk;   // 100MHz 仿真时钟 (10ns 周期, 加快仿真)

    reg samp_en = 0;
    reg rst_n = 0;

    // ============================================================
    // DUT 参数
    // ============================================================
    // ym2413 频率: step = fnum << block, phase += step, idx = phase>>10
    // 采样率 49716Hz (ym2413), idx 周期 = 2^16 / step
    // 音频频率 = step × samplerate / 2^16 (因为 idx = phase>>10, 6-bit, 周期 64)
    //   phase 溢出 2^16 时 idx 走完 64 点 = 1 个正弦周期
    //
    // 正确推导:
    //   phase 是 16-bit, 每个 sample phase += step
    //   idx = phase[15:10] (高 6 位), 0-63 循环
    //   1 个正弦周期 = idx 走 64 步 = phase 增加 64×1024 = 65536 = 2^16
    //   → 每 sample phase 增加 step, 要 N 个 sample 走完 2^16
    //   → N = 2^16 / step
    //   → 音频频率 = samplerate / N = samplerate × step / 2^16
    //
    // 目标: 440Hz, samplerate=66300
    //   step = 440 × 65536 / 66300 = 434.7 ≈ 435
    //
    // 但 FM 里 OP1 和 OP2 频率比决定音色:
    //   mul_m:m = 频率比, 通常 carrier(OP2) 基频, modulator(OP1) 可整数倍
    //   测试: OP1 = OP2 = 440Hz (mul 1:1), 纯 FM 音色
    //   再测: OP1 = 2×440 (mul 2:1), 更亮音色

    // 参数组 1: 1:1 频率比 (柔和 FM)
    wire [15:0] STEP_M_1 = 16'd435;   // OP1 = 440Hz
    wire [15:0] STEP_C_1 = 16'd435;   // OP2 = 440Hz (1:1)

    // 参数组 2: 2:1 频率比 (明亮 FM, 类似 trumpet)
    wire [15:0] STEP_M_2 = 16'd870;   // OP1 = 880Hz (2× carrier)
    wire [15:0] STEP_C_2 = 16'd435;   // OP2 = 440Hz

    // 当前测试参数 (切换测两种音色)
    reg [15:0] step_m = 16'd435;
    reg [15:0] step_c = 16'd435;
    reg [4:0]  env_level_m = 5'd31;   // 满调制深度 (FM 音色)
    reg [4:0]  env_level_c = 5'd31;   // 满音量
    reg [3:0]  vol = 4'd0;            // 最大音量 (ym2413: vol=0 最响)

    // ============================================================
    // DUT
    // ============================================================
    wire signed [7:0] carrier_out;
    wire [7:0]  dac_out;

    fm6_core u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .samp_en(samp_en),
        .step_m(step_m),
        .step_c(step_c),
        .env_level_m(env_level_m),
        .env_level_c(env_level_c),
        .vol(vol),
        .carrier_out(carrier_out),
        .dac_out(dac_out)
    );

    // ============================================================
    // 采样节拍生成
    // ============================================================
    // 每 SAMPLE_DIV 个 clk 产生 1 个 samp_en 脉冲
    // samp_en 频率 = 100MHz / SAMPLE_DIV
    // 直接用这个频率做 WAV 采样率 (不做额外下采样, 简化仿真)
    localparam SAMPLE_DIV = 1508;  // 100MHz/1508 ≈ 66.3kHz (设计采样率)

    reg [15:0] samp_cnt = 0;
    always @(posedge clk) begin
        if (samp_cnt == SAMPLE_DIV - 1) begin
            samp_cnt <= 0;
            samp_en <= 1'b1;
        end else begin
            samp_cnt <= samp_cnt + 1'b1;
            samp_en <= 1'b0;
        end
    end

    // ============================================================
    // WAV 输出
    // ============================================================
    localparam SAMPLE_RATE = 66300;              // 目标采样率
    localparam NUM_SAMPLES = 33000;              // 仿真样本数 (~0.5 秒 @ 66.3kHz)

    integer wav_fd;
    integer i;

    // WAV 文件头 (8-bit unsigned mono)
    task write_wav_header;
        integer file_size;
        begin
            // 数据大小
            file_size = NUM_SAMPLES;  // 8-bit/sample
            wav_fd = $fopen("fm6_note.wav", "wb");

            // RIFF header
            $fwrite(wav_fd, "RIFF");
            $fwrite(wav_fd, "%c%c%c%c",
                (36+file_size)%256, (36+file_size)/256%256,
                (36+file_size)/65536%256, (36+file_size)/16777216);
            $fwrite(wav_fd, "WAVE");

            // fmt chunk
            $fwrite(wav_fd, "fmt ");
            $fwrite(wav_fd, "%c%c%c%c", 16,0,0,0);        // chunk size = 16
            $fwrite(wav_fd, "%c%c", 1, 0);                 // audio format = 1 (PCM)
            $fwrite(wav_fd, "%c%c", 1, 0);                 // num channels = 1
            $fwrite(wav_fd, "%c%c%c%c",
                SAMPLE_RATE%256, SAMPLE_RATE/256%256,
                SAMPLE_RATE/65536%256, SAMPLE_RATE/16777216);  // sample rate
            $fwrite(wav_fd, "%c%c%c%c",
                SAMPLE_RATE%256, SAMPLE_RATE/256%256,
                SAMPLE_RATE/65536%256, SAMPLE_RATE/16777216);  // byte rate = sr × 1
            $fwrite(wav_fd, "%c%c", 1, 0);                 // block align = 1
            $fwrite(wav_fd, "%c%c", 8, 0);                 // bits per sample = 8

            // data chunk
            $fwrite(wav_fd, "data");
            $fwrite(wav_fd, "%c%c%c%c",
                file_size%256, file_size/256%256,
                file_size/65536%256, file_size/16777216);
        end
    endtask

    // ============================================================
    // 主流程
    // ============================================================
    integer sample_count = 0;

    initial begin
        // 初始化
        rst_n = 0;
        #100;
        rst_n = 1;
        #50;

        write_wav_header;

        $display("[%0t] FM6 note test started: step_m=%0d step_c=%0d (1:1 ratio, 440Hz)",
                 $time, step_m, step_c);
        $display("[%0t] env_m=%0d env_c=%0d vol=%0d",
                 $time, env_level_m, env_level_c, vol);

        // 监控前几个采样
        // 主循环由 samp_en 驱动
    end

    // WAV 写入 (每个 samp_en 写一个样本, 无下采样)
    always @(posedge clk) begin
        if (samp_en && sample_count < NUM_SAMPLES) begin
            $fwrite(wav_fd, "%c", dac_out);
            sample_count <= sample_count + 1;

            // 前 20 个采样打印调试
            if (sample_count < 20) begin
                $display("  samp[%0d]: phase_m=%h idx_m=%0d mod_out=%0d", sample_count, u_dut.phase_m, u_dut.idx_m, u_dut.mod_out);
                $display("         phase_c=%h idx_c=%0d carrier=%0d dac=%0d", u_dut.phase_c, u_dut.idx_c, carrier_out, dac_out);
            end
        end
    end

    // 结束
    always @(posedge clk) begin
        if (sample_count >= NUM_SAMPLES) begin
            $display("[%0t] Done: %0d samples written to fm6_note.wav", $time, sample_count);
            $fclose(wav_fd);
            $finish;
        end
    end

endmodule
