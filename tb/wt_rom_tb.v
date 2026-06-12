`timescale 1ns/1ps
// wt_rom_tb.v — 128点单通道 WT 合成器 testbench
// 对齐 STC32G wt.c: phase[15:5]&0x7F, step=freq*8192/32051
// 架构: 查表累加器, 39SF040(ROM) + 62256(RAM) + 2×74283(ALU)
// level 16级, vol 16级 (AY-3-8910 style)
module wt_rom_tb;

reg clk;

localparam SAMPLE_RATE = 32051;
localparam CLK_HZ      = 10_000_000;
localparam SAMPLE_DIV  = CLK_HZ / SAMPLE_RATE;

reg [15:0] sample_cnt;
wire sample_clk = (sample_cnt == 0);
always @(posedge clk) begin
    if (sample_cnt == 0) sample_cnt <= SAMPLE_DIV - 1;
    else sample_cnt <= sample_cnt - 1;
end

// ---- 39SF040 ROM (512K x 8) ----
// 地址: wave_idx[2]<<14 | level[4]<<10 | vol[4]<<7 | idx[7]
reg [7:0] rom_data [0:524287];
initial begin
    $readmemh("rom/wt_39sf040.hex", rom_data);
end

// ---- 通道状态 ----
reg [15:0] phase;
reg [15:0] step_val;
reg [3:0]  level;       // 0-15
reg [2:0]  env_state;   // 0=off 1=atk 2=sus 3=rel
reg [7:0]  env_cnt;
reg [3:0]  vol;         // 0-15
reg [1:0]  wave_idx;    // 0=sqr 1=sine 2=saw 3=noise
reg [7:0]  env_rate;
reg signed [7:0] dac_out;
reg running;

// ---- step: freq * 8192 / 32051 (STC32G 公式) ----
localparam [15:0] STEP_C4 = 16'd67;
localparam [15:0] STEP_A4 = 16'd112;

// ---- ROM 地址 (组合逻辑, 每拍更新) ----
reg [18:0] rom_addr;

integer fd, i;

always @(posedge clk) begin
    if (sample_clk && running) begin
        phase = phase + step_val;
        rom_addr = {wave_idx, level, vol, phase[11:5]};
        dac_out = $signed(rom_data[rom_addr]);

        if (env_state != 0) begin
            if (env_cnt >= env_rate) begin
                env_cnt <= 0;
                case (env_state)
                1: begin
                    if (level < 15) level <= level + 1;
                    else env_state <= 2;
                end
                2: ; // sustain
                3: begin
                    if (level > 0) level <= level - 1;
                    else begin
                        level <= 0;
                        env_state <= 0;
                    end
                end
                endcase
            end else begin
                env_cnt <= env_cnt + 1;
            end
        end
    end
end

initial begin
    clk = 0;
    fd = $fopen("wt_output.csv", "w");
    $fdisplay(fd, "sample,dac_signed");

    phase = 0; step_val = 0; level = 0; env_state = 0;
    env_cnt = 0; vol = 0; wave_idx = 0; env_rate = 0;
    dac_out = 0; running = 0;
    sample_cnt = SAMPLE_DIV - 1;

    #200;

    // Test 1: sine C4 attack+sustain
    phase = 0; step_val = STEP_C4;
    level = 0; env_state = 1; env_cnt = 0;
    vol = 15; wave_idx = 2'd1; env_rate = 64;
    running = 1;

    for (i = 0; i < 16000; i = i + 1) begin
        repeat (312) clk = #50 ~clk;
        $fdisplay(fd, "%0d,%0d", i, $signed(dac_out));
    end

    // Test 2: release
    env_state = 3;
    for (i = 0; i < 4000; i = i + 1) begin
        repeat (312) clk = #50 ~clk;
        $fdisplay(fd, "%0d,%0d", i + 16000, $signed(dac_out));
    end

    // Test 3: sqr A4
    phase = 0; step_val = STEP_A4;
    level = 0; env_state = 1; env_cnt = 0;
    wave_idx = 2'd0; env_rate = 64;
    for (i = 0; i < 8000; i = i + 1) begin
        repeat (312) clk = #50 ~clk;
        $fdisplay(fd, "%0d,%0d", i + 20000, $signed(dac_out));
    end

    // Test 4: saw C4
    phase = 0; step_val = STEP_C4;
    level = 0; env_state = 1; env_cnt = 0;
    wave_idx = 2'd2; env_rate = 64;
    for (i = 0; i < 8000; i = i + 1) begin
        repeat (312) clk = #50 ~clk;
        $fdisplay(fd, "%0d,%0d", i + 28000, $signed(dac_out));
    end

    // Test 5: noise C4
    phase = 0; step_val = STEP_C4;
    level = 0; env_state = 1; env_cnt = 0;
    wave_idx = 2'd3; env_rate = 64;
    for (i = 0; i < 8000; i = i + 1) begin
        repeat (312) clk = #50 ~clk;
        $fdisplay(fd, "%0d,%0d", i + 36000, $signed(dac_out));
    end

    $fclose(fd);
    $display("Done. 44000 samples.");
    $finish;
end

endmodule
