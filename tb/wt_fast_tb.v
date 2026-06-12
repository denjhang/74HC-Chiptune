`timescale 1ns/1ps

module wt_fast_tb;

reg clk;

// 采样率: 32051Hz @10MHz → div=312
localparam SAMPLE_DIV = 312;
localparam WAVE_POINTS = 128;

reg [15:0] sample_cnt;
wire sample_clk = (sample_cnt == 0);
always @(posedge clk) begin
    if (sample_cnt == 0) sample_cnt <= SAMPLE_DIV - 1;
    else sample_cnt <= sample_cnt - 1;
end

// 128 点正弦波 (±31, 有符号 8-bit) — 来自 STC32G 移植版 wt.c wave 4
reg signed [7:0] wave_rom [0:WAVE_POINTS-1];
initial begin
    $readmemh("rom/sin_128.hex", wave_rom);
end

// 频率表: step = freq * 8192 / 32051 (与移植版一致, 13-bit 精度)
// C4: 261.6 * 8192 / 32051 = 66.9 ≈ 67
// A4: 440.0 * 8192 / 32051 = 112.4 ≈ 112
reg [15:0] phase0;
wire [15:0] step0 = 16'd67;
reg [7:0] env0;
reg [2:0] state0;
reg [7:0] cnt0;

reg [15:0] phase1;
wire [15:0] step1 = 16'd112;
reg [7:0] env1;
reg [2:0] state1;
reg [7:0] cnt1;

reg signed [15:0] ch0, ch1, mix;
reg signed [15:0] env0_ext, env1_ext;
reg [7:0] dac_out;

integer fd, i;

always @(posedge clk) begin
    if (sample_clk) begin
        // 通道 0
        if (state0 != 0) begin
            phase0 <= phase0 + step0;
            env0_ext <= $signed({1'b0, env0}) + 1;
            ch0 <= wave_rom[(phase0[15:5]) & 8'h7F] * env0_ext;
        end else ch0 <= 0;

        // 通道 1
        if (state1 != 0) begin
            phase1 <= phase1 + step1;
            env1_ext <= $signed({1'b0, env1}) + 1;
            ch1 <= wave_rom[(phase1[15:5]) & 8'h7F] * env1_ext;
        end else ch1 <= 0;

        // 混音: >>5 (与移植版 >>10 对应, vol=31 简化)
        mix <= (ch0 + ch1) >>> 5;
        dac_out <= mix[7:0];

        // 包络 ch0 (每 64 采样步进)
        if (state0 != 0) begin
            cnt0 <= cnt0 + 1;
            if (cnt0 == 64) begin
                cnt0 <= 0;
                case (state0)
                    1: if (env0 < 30) env0 <= env0 + 1; else state0 <= 2;
                    2: if (env0 > 13) env0 <= env0 - 1; else state0 <= 3;
                    3: ; // sustain 保持
                    4: if (env0 > 0) env0 <= env0 - 1; else begin env0 <= 0; state0 <= 0; end
                endcase
            end
        end

        // 包络 ch1
        if (state1 != 0) begin
            cnt1 <= cnt1 + 1;
            if (cnt1 == 64) begin
                cnt1 <= 0;
                case (state1)
                    1: if (env1 < 30) env1 <= env1 + 1; else state1 <= 2;
                    2: if (env1 > 13) env1 <= env1 - 1; else state1 <= 3;
                    3: ;
                    4: if (env1 > 0) env1 <= env1 - 1; else begin env1 <= 0; state1 <= 0; end
                endcase
            end
        end
    end
end

initial begin
    clk = 0;
    fd = $fopen("wt_output.csv", "w");
    $fdisplay(fd, "sample,dac_signed");

    phase0 = 0; phase1 = 0;
    env0 = 0; env1 = 0;
    state0 = 0; state1 = 0;
    cnt0 = 0; cnt1 = 0;
    ch0 = 0; ch1 = 0; mix = 0; dac_out = 0;
    sample_cnt = 0;

    // ch0 note_on
    state0 = 1; env0 = 0; cnt0 = 0; phase0 = 0;

    for (i = 0; i < 16000; i = i + 1) begin
        repeat (312) clk = #50 ~clk;
        $fdisplay(fd, "%0d,%0d", i, $signed(dac_out));
        if (i == 8000) begin state1 = 1; env1 = 0; cnt1 = 0; phase1 = 0; end
    end

    $fclose(fd);
    $display("Done. 16000 samples.");
    $finish;
end

endmodule
