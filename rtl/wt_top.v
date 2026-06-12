`timescale 1ns/1ps

module wt_top (
    input  wire        clk,
    input  wire [7:0]  addr,
    inout  wire [7:0]  data,
    input  wire        cs_n,
    input  wire        wr_n,
    input  wire        rd_n,
    input  wire        rst_n,
    output wire [7:0]  dac_out
);

// ---- 寄存器映射 ----
// 0x00: CTRL  [0]=run [1]=ch0_on [2]=ch0_off [3]=ch1_on [4]=ch1_off
// 0x01-02: ch0 step (16-bit)
// 0x03: ch0 attack rate (env step interval)
// 0x04-05: ch1 step (16-bit)
// 0x06: ch1 attack rate
// 0x07-08: sample divider (16-bit)

reg [7:0]  ctrl;
reg [7:0]  step0_lo, step0_hi;
reg [7:0]  step1_lo, step1_hi;
reg [7:0]  atk_rate0, atk_rate1;
reg [15:0] sample_div;

wire [15:0] step0 = {step0_hi, step0_lo};
wire [15:0] step1 = {step1_hi, step1_lo};

// ---- 总线 ----
wire bus_wr = ~cs_n & ~wr_n;
wire bus_rd = ~cs_n & ~rd_n;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ctrl <= 0;
        step0_lo <= 0; step0_hi <= 0;
        step1_lo <= 0; step1_hi <= 0;
        atk_rate0 <= 64; atk_rate1 <= 64;
        sample_div <= 16'h0138;
    end else if (bus_wr) begin
        case (addr)
            8'h00: ctrl <= data;
            8'h01: step0_lo <= data;
            8'h02: step0_hi <= data;
            8'h03: atk_rate0 <= data;
            8'h04: step1_lo <= data;
            8'h05: step1_hi <= data;
            8'h06: atk_rate1 <= data;
            8'h07: sample_div[7:0] <= data;
            8'h08: sample_div[15:8] <= data;
            default: ;
        endcase
    end
end

reg [7:0] data_out;
assign data = bus_rd ? data_out : 8'bz;

always @(*) begin
    case (addr)
        8'h00: data_out = ctrl;
        8'h01: data_out = step0_lo;
        8'h02: data_out = step0_hi;
        8'h03: data_out = atk_rate0;
        8'h04: data_out = step1_lo;
        8'h05: data_out = step1_hi;
        8'h06: data_out = atk_rate1;
        default: data_out = 8'hFF;
    endcase
end

// ---- 采样率分频 ----
reg [15:0] sample_cnt;
wire sample_clk = (sample_cnt == 0);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        sample_cnt <= 16'h0138;
    else if (sample_cnt == 0)
        sample_cnt <= sample_div - 1;
    else
        sample_cnt <= sample_cnt - 1;
end

// ---- 波形 ROM (64x8 有符号) ----
localparam WAVE_POINTS = 64;
reg [7:0] wave_rom [0:WAVE_POINTS-1];
initial begin
    $readmemh("rom/sin_64.hex", wave_rom);
end

// ---- 通道 0 ----
reg [15:0] phase0;
reg [7:0]  env_level0;      // 0-255, 直接做音量
reg [2:0]  env_state0;      // 0=off 1=atk 2=sus 3=rel
reg [7:0]  env_cnt0;

// ---- 通道 1 ----
reg [15:0] phase1;
reg [7:0]  env_level1;
reg [2:0]  env_state1;
reg [7:0]  env_cnt1;

// ---- 控制脉冲 ----
reg ctrl_prev;
wire ctrl_rise = (ctrl != 0) & (ctrl_prev == 0);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        ctrl_prev <= 0;
    else
        ctrl_prev <= ctrl;
end

// ---- WT 核心 ----
reg signed [15:0] ch0_out, ch1_out;
reg signed [15:0] mix_out;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        phase0 <= 0; phase1 <= 0;
        env_level0 <= 0; env_level1 <= 0;
        env_state0 <= 0; env_state1 <= 0;
        env_cnt0 <= 0; env_cnt1 <= 0;
        ch0_out <= 0; ch1_out <= 0;
        mix_out <= 0;
    end else begin
        // note_on/note_off
        if (ctrl_rise) begin
            if (ctrl[1]) begin env_state0 <= 1; env_level0 <= 0; env_cnt0 <= 0; phase0 <= 0; end
            if (ctrl[2]) begin env_state0 <= 3; end
            if (ctrl[3]) begin env_state1 <= 1; env_level1 <= 0; env_cnt1 <= 0; phase1 <= 0; end
            if (ctrl[4]) begin env_state1 <= 3; end
        end

        if (sample_clk && ctrl[0]) begin
            // ---- 通道 0 ----
            if (env_state0 != 0) begin
                phase0 <= phase0 + step0;
                // 波形 ROM × env_level (8-bit × 8-bit = 16-bit, 取高8位)
                ch0_out <= $signed({1'b0, wave_rom[phase0[15:10]]}) * $signed({1'b0, env_level0});
            end else begin
                ch0_out <= 0;
            end

            // ---- 通道 1 ----
            if (env_state1 != 0) begin
                phase1 <= phase1 + step1;
                ch1_out <= $signed({1'b0, wave_rom[phase1[15:10]]}) * $signed({1'b0, env_level1});
            end else begin
                ch1_out <= 0;
            end

            // ---- 混音 (取高8位, 带裁剪) ----
            mix_out <= (ch0_out + ch1_out) >>> 4;

            // ---- 通道 0 包络 ----
            if (env_state0 != 0) begin
                env_cnt0 <= env_cnt0 + 1;
                if (env_cnt0 >= atk_rate0) begin
                    env_cnt0 <= 0;
                    case (env_state0)
                        1: begin // attack: 上升到 255
                            if (env_level0 < 255)
                                env_level0 <= env_level0 + 4;
                            else begin
                                env_level0 <= 255;
                                env_state0 <= 2; // → sustain (保持)
                            end
                        end
                        2: begin // sustain: 保持不衰减
                            // 什么都不做，持续发声
                        end
                        3: begin // release: 衰减到 0
                            if (env_level0 > 4)
                                env_level0 <= env_level0 - 4;
                            else begin
                                env_level0 <= 0;
                                env_state0 <= 0;
                            end
                        end
                    endcase
                end
            end

            // ---- 通道 1 包络 ----
            if (env_state1 != 0) begin
                env_cnt1 <= env_cnt1 + 1;
                if (env_cnt1 >= atk_rate1) begin
                    env_cnt1 <= 0;
                    case (env_state1)
                        1: begin
                            if (env_level1 < 255)
                                env_level1 <= env_level1 + 4;
                            else begin
                                env_level1 <= 255;
                                env_state1 <= 2;
                            end
                        end
                        2: begin
                            // sustain: 保持
                        end
                        3: begin
                            if (env_level1 > 4)
                                env_level1 <= env_level1 - 4;
                            else begin
                                env_level1 <= 0;
                                env_state1 <= 0;
                            end
                        end
                    endcase
                end
            end
        end
    end
end

assign dac_out = mix_out[7:0];

endmodule
