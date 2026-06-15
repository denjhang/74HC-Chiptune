`timescale 1ns/1ps
// wt_rom_tb.v — 128点 4通道 WT 合成器 testbench
// 对齐 STC32G wt.c: phase[12:6]&0x7F, step=freq*8192/32051
// 6波形(sqr/sq12/sq25/sine/saw/noise), 16level, 32vol
// 架构: 查表累加器, 39SF040(ROM) + 62256(RAM) + 2×74283(ALU)
module wt_rom_tb;

reg clk;

localparam SAMPLE_RATE = 32051;
localparam CLK_HZ      = 10_000_000;
localparam SAMPLE_DIV  = CLK_HZ / SAMPLE_RATE;
localparam CHANS       = 4;

reg [15:0] sample_cnt;
wire sample_clk = (sample_cnt == 0);
always @(posedge clk) begin
    if (sample_cnt == 0) sample_cnt <= SAMPLE_DIV - 1;
    else sample_cnt <= sample_cnt - 1;
end

// ---- 39SF040 ROM (512K x 8) ----
reg [7:0] rom_data [0:524287];
initial begin
    $readmemh("rom/wt_39sf040.hex", rom_data);
end

// ---- 4 通道状态 ----
reg [15:0] phase   [0:3];
reg [15:0] step_val[0:3];
reg [3:0]  level   [0:3];
reg [2:0]  env_state[0:3];
reg [7:0]  env_cnt [0:3];
reg [4:0]  vol     [0:3];  // 0-31
reg [2:0]  wave_idx[0:3];  // 0-5
reg [7:0]  env_rate[0:3];

reg signed [15:0] dac_out;
reg running;

// ---- step: freq * 8192 / 32051 ----
localparam [15:0] STEP_C4  = 16'd67;
localparam [15:0] STEP_E4  = 16'd84;
localparam [15:0] STEP_G4  = 16'd100;
localparam [15:0] STEP_C5  = 16'd134;

integer fd, i, ch;
reg [18:0] rom_addr;
reg signed [15:0] ch_out [0:3];

always @(posedge clk) begin
    if (sample_clk && running) begin
        dac_out = 0;
        for (ch = 0; ch < CHANS; ch = ch + 1) begin
            if (env_state[ch] != 0) begin
                // phase 累加
                phase[ch] = phase[ch] + step_val[ch];
                // ROM 查表
                rom_addr = {wave_idx[ch], level[ch], vol[ch], phase[ch][12:6]};
                ch_out[ch] = $signed(rom_data[rom_addr]);
                // 混音
                dac_out = dac_out + ch_out[ch];
                // 包络
                if (env_cnt[ch] >= env_rate[ch]) begin
                    env_cnt[ch] = 0;
                    case (env_state[ch])
                    1: begin
                        if (level[ch] < 15) level[ch] = level[ch] + 1;
                        else env_state[ch] = 2;
                    end
                    2: ; // sustain
                    3: begin
                        if (level[ch] > 0) level[ch] = level[ch] - 1;
                        else begin
                            level[ch] = 0;
                            env_state[ch] = 0;
                        end
                    end
                    endcase
                end else begin
                    env_cnt[ch] = env_cnt[ch] + 1;
                end
            end else begin
                ch_out[ch] = 0;
            end
        end
        // 裁剪
        if (dac_out > 127) dac_out = 127;
        if (dac_out < -128) dac_out = -128;
    end
end

initial begin
    clk = 0;
    fd = $fopen("wt_output.csv", "w");
    $fdisplay(fd, "sample,dac_signed");

    for (ch = 0; ch < CHANS; ch = ch + 1) begin
        phase[ch] = 0; step_val[ch] = 0; level[ch] = 0;
        env_state[ch] = 0; env_cnt[ch] = 0; vol[ch] = 0;
        wave_idx[ch] = 0; env_rate[ch] = 0; ch_out[ch] = 0;
    end
    dac_out = 0; running = 0;
    sample_cnt = SAMPLE_DIV - 1;

    #200;

    // ---- Test 1: C major chord (C4+E4+G4) sine ----
    // ch0: C4 sine
    phase[0] = 0; step_val[0] = STEP_C4;
    level[0] = 0; env_state[0] = 1; env_cnt[0] = 0;
    vol[0] = 31; wave_idx[0] = 3; env_rate[0] = 64;
    // ch1: E4 sine
    phase[1] = 0; step_val[1] = STEP_E4;
    level[1] = 0; env_state[1] = 1; env_cnt[1] = 0;
    vol[1] = 31; wave_idx[1] = 3; env_rate[1] = 64;
    // ch2: G4 sine
    phase[2] = 0; step_val[2] = STEP_G4;
    level[2] = 0; env_state[2] = 1; env_cnt[2] = 0;
    vol[2] = 31; wave_idx[2] = 3; env_rate[2] = 64;
    running = 1;

    for (i = 0; i < 16000; i = i + 1) begin
        repeat (312) clk = #50 ~clk;
        $fdisplay(fd, "%0d,%0d", i, $signed(dac_out));
    end

    // ---- Test 2: release all ----
    for (ch = 0; ch < CHANS; ch = ch + 1)
        if (env_state[ch] != 0) env_state[ch] = 3;

    for (i = 0; i < 4000; i = i + 1) begin
        repeat (312) clk = #50 ~clk;
        $fdisplay(fd, "%0d,%0d", i + 16000, $signed(dac_out));
    end

    // ---- Test 3: multi-waveform (sqr C4 + saw E4 + noise G4 + sine C5) ----
    phase[0] = 0; step_val[0] = STEP_C4;
    level[0] = 0; env_state[0] = 1; env_cnt[0] = 0;
    vol[0] = 31; wave_idx[0] = 0; env_rate[0] = 64; // sqr

    phase[1] = 0; step_val[1] = STEP_E4;
    level[1] = 0; env_state[1] = 1; env_cnt[1] = 0;
    vol[1] = 31; wave_idx[1] = 4; env_rate[1] = 64; // saw

    phase[2] = 0; step_val[2] = STEP_G4;
    level[2] = 0; env_state[2] = 1; env_cnt[2] = 0;
    vol[2] = 31; wave_idx[2] = 5; env_rate[2] = 64; // noise

    phase[3] = 0; step_val[3] = STEP_C5;
    level[3] = 0; env_state[3] = 1; env_cnt[3] = 0;
    vol[3] = 31; wave_idx[3] = 3; env_rate[3] = 64; // sine

    for (i = 0; i < 16000; i = i + 1) begin
        repeat (312) clk = #50 ~clk;
        $fdisplay(fd, "%0d,%0d", i + 20000, $signed(dac_out));
    end

    $fclose(fd);
    $display("Done. 36000 samples.");
    $finish;
end

endmodule
