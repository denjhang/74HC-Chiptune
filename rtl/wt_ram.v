`timescale 1ns/1ps
// wt_ram.v — 4通道 WT 合成器, 62256 RAM + 74161 微程序步进器
// 架构: 查表累加器, 39SF040(ROM) + 62256(RAM) + 2×74283(ALU)
// SPFM 总线: D0-7, /CS, A0, /WR, /RD, /RST
//
// 9 IC: 74161(1) + 74283(2) + 74377(2) + 74157(1) + 74138+7404(2) + 39SF040(1) + 62256(1)
//
// 微程序时序 (10MHz, 32051Hz 采样率):
//   每采样周期 312 个时钟
//   4通道 × 20步 = 80 步, 剩余 232 空闲 (足够 SPFM 操作)
//   每步 1 个时钟
//
// 时序约定:
//   RAM 读: 当前周期设地址+OE, 下个周期锁存 ram_io
//   RAM 写: 当前周期设地址+数据+WE, 当周期写入
//   ROM 读: 当前周期设地址, 下个周期锁存 rom_data
//
// 每通道 20 步:
//   0: 读 phase_lo  (设地址)
//   1: 锁存 phase_lo → acc_lo, 读 step_lo  (设地址)
//   2: 锁存 step_lo → step_lo_r
//      加法: acc_lo = acc_lo + step_lo_r
//      写回 phase_lo
//   3: 读 phase_hi  (设地址)
//   4: 锁存 phase_hi → acc_hi, 读 step_hi  (设地址)
//   5: 锁存 step_hi → step_hi_r
//      加法: acc_hi = acc_hi + step_hi_r + carry
//      写回 phase_hi
//   6: 读 level  (设地址)
//   7: 锁存 level → level_r, 读 vol  (设地址)
//   8: 锁存 vol → vol_r, 读 wave_idx  (设地址)
//   9: 锁存 wave_idx → wave_idx_r, 读 env_state  (设地址)
//  10: 锁存 env_state → env_state_r
//      如果活跃: 组合 ROM 地址 {wave_idx, level, vol, phase[12:6]}
//  11: 如果活跃: 锁存 ROM 输出, 累加到 mix_sum
//  12: 读 env_cnt  (设地址)
//  13: 锁存 env_cnt → env_cnt_r, 读 env_rate  (设地址)
//  14: 锁存 env_rate → env_rate_r, 包络计算
//  15: 写 env_state 回 RAM
//  16: 写 level 回 RAM
//  17: 写 env_cnt 回 RAM
//  18: 空操作 (写 dac_out 到 RAM — 可选, 调试用)
//  19: 空操作

module wt_ram (
    input  wire        clk,
    inout  wire [7:0]  d,        // SPFM 数据总线
    input  wire        cs_n,
    input  wire        a0,
    input  wire        wr_n,
    input  wire        rd_n,
    input  wire        rst_n,
    // 外部 ROM 接口 (39SF040)
    output reg  [18:0] rom_addr,
    input  wire [7:0]  rom_data,
    // 外部 RAM 接口 (62256)
    output reg  [14:0] ram_addr,
    inout  wire [7:0]  ram_io,
    output reg         ram_we_n,
    output reg         ram_oe_n,
    output reg         ram_cs_n,
    // DAC 输出
    output reg  [7:0]  dac_out
);

// ---- RAM 寄存器映射 (62256) ----
// 每通道 16 字节, 4通道 = 64 字节
// ch_base = ch[1:0] << 4
localparam [3:0] O_PHASE_LO  = 0;
localparam [3:0] O_PHASE_HI  = 1;
localparam [3:0] O_STEP_LO   = 2;
localparam [3:0] O_STEP_HI   = 3;
localparam [3:0] O_LEVEL     = 4;
localparam [3:0] O_ENV_STATE = 5;
localparam [3:0] O_ENV_CNT   = 6;
localparam [3:0] O_VOL       = 7;
localparam [3:0] O_DAC_OUT   = 8;
localparam [3:0] O_WAVE_IDX  = 9;
localparam [3:0] O_ENV_RATE  = 10;

localparam SAMPLE_DIV = 312;
localparam CHANS = 4;
localparam STEPS_PER_CH = 32;         // 2 的幂, 便于位切片
localparam TOTAL_STEPS = CHANS * STEPS_PER_CH; // 128

// ---- 采样率分频 ----
reg [15:0] sample_cnt;
wire sample_start = (sample_cnt == 0);

// ---- 微程序步进器 (74161) ----
// 0 ~ (TOTAL_STEPS-1): 微程序执行
// TOTAL_STEPS ~ 311: 空闲 (SPFM 操作)
reg [7:0] ustep;
wire [1:0] uch = ustep[6:5];          // 通道 0-3 (32 步对齐)
wire [4:0] ums = ustep[4:0];          // 微步 0-31
wire [14:0] ch_base = {9'b0, uch, 4'b0};

// ---- 工作寄存器 (74377 锁存) ----
reg [7:0]  acc_lo;
reg [7:0]  acc_hi;
reg        carry;
reg [3:0]  level_r;
reg [2:0]  env_state_r;
reg [7:0]  env_cnt_r;
reg [4:0]  vol_r;
reg [2:0]  wave_idx_r;
reg [7:0]  env_rate_r;
reg signed [15:0] mix_sum;

// RAM 驱动
reg [7:0]  ram_wdata;
reg        ram_drive_en;
assign ram_io = ram_drive_en ? ram_wdata : 8'bz;

// ---- 总线同步 (YM2413 风格) ----
reg [7:0] d_latch;
always @(*) begin
    if (!cs_n && !wr_n)
        d_latch = d;
    else
        d_latch = d_latch;
end

wire addr_req_async = ~cs_n & ~wr_n & ~a0 & rst_n;
wire data_req_async = ~cs_n & ~wr_n &  a0 & rst_n;

reg addr_req_meta, addr_req_sync, addr_req_prev, addr_req_pulse;
reg data_req_meta, data_req_sync, data_req_prev, data_req_pulse;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        addr_req_meta <= 0; addr_req_sync <= 0; addr_req_prev <= 0;
        data_req_meta <= 0; data_req_sync <= 0; data_req_prev <= 0;
        addr_req_pulse <= 0; data_req_pulse <= 0;
    end else begin
        addr_req_meta <= addr_req_async;
        addr_req_sync <= addr_req_meta;
        data_req_meta <= data_req_async;
        data_req_sync <= data_req_meta;
        addr_req_pulse <= addr_req_sync & ~addr_req_prev;
        data_req_pulse <= data_req_sync & ~data_req_prev;
        addr_req_prev <= addr_req_sync;
        data_req_prev <= data_req_sync;
    end
end

// ---- 主机寄存器 ----
reg [7:0]  reg_addr;
reg [1:0]  host_ch;
reg [2:0]  host_wave_idx [0:3];
reg [4:0]  host_vol      [0:3];
reg [7:0]  host_env_rate [0:3];
reg [15:0] host_step     [0:3];
reg [3:0]  ch_active;

// SPFM 读
reg [7:0] data_out;
wire bus_rd = ~cs_n & ~rd_n;
assign d = bus_rd ? data_out : 8'bz;

// SPFM 挂起操作
reg        spfm_pending;
reg [3:0]  spfm_op;     // 1=note_on, 2=note_off
reg [1:0]  spfm_ch;
reg [3:0]  spfm_phase;  // note_on 多阶段

// ---- 主 always 块 ----
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sample_cnt <= SAMPLE_DIV - 1;
        ustep <= 8'd128;
        acc_lo <= 0; acc_hi <= 0; carry <= 0;
        level_r <= 0; env_state_r <= 0; env_cnt_r <= 0;
        vol_r <= 0; wave_idx_r <= 0; env_rate_r <= 0;
        mix_sum <= 0;
        ram_addr <= 0; ram_we_n <= 1; ram_oe_n <= 1; ram_cs_n <= 1;
        ram_wdata <= 0; ram_drive_en <= 0;
        rom_addr <= 0;
        dac_out <= 0;
        reg_addr <= 0; host_ch <= 0;
        host_wave_idx[0] <= 0; host_wave_idx[1] <= 0;
        host_wave_idx[2] <= 0; host_wave_idx[3] <= 0;
        host_vol[0] <= 0; host_vol[1] <= 0;
        host_vol[2] <= 0; host_vol[3] <= 0;
        host_env_rate[0] <= 0; host_env_rate[1] <= 0;
        host_env_rate[2] <= 0; host_env_rate[3] <= 0;
        host_step[0] <= 0; host_step[1] <= 0;
        host_step[2] <= 0; host_step[3] <= 0;
        ch_active <= 0;
        data_out <= 8'hFF;
        spfm_pending <= 0; spfm_op <= 0; spfm_ch <= 0; spfm_phase <= 0;
    end else begin
        // ---- 采样率分频 ----
        if (sample_cnt == 0)
            sample_cnt <= SAMPLE_DIV - 1;
        else
            sample_cnt <= sample_cnt - 1;

        // ---- RAM 默认: 空闲 ----
        ram_we_n <= 1;
        ram_oe_n <= 1;
        ram_cs_n <= 1;
        ram_drive_en <= 0;

        // ---- SPFM: 地址锁存 ----
        if (addr_req_pulse)
            reg_addr <= d_latch;

        // ---- SPFM: 数据锁存 ----
        if (data_req_pulse) begin
            case (reg_addr)
            8'h00: host_ch <= d_latch[1:0];
            8'h01: case (host_ch)
                0: host_wave_idx[0] <= d_latch[2:0];
                1: host_wave_idx[1] <= d_latch[2:0];
                2: host_wave_idx[2] <= d_latch[2:0];
                3: host_wave_idx[3] <= d_latch[2:0];
                endcase
            8'h02: case (host_ch)
                0: host_vol[0] <= d_latch[4:0];
                1: host_vol[1] <= d_latch[4:0];
                2: host_vol[2] <= d_latch[4:0];
                3: host_vol[3] <= d_latch[4:0];
                endcase
            8'h03: case (host_ch)
                0: host_env_rate[0] <= d_latch;
                1: host_env_rate[1] <= d_latch;
                2: host_env_rate[2] <= d_latch;
                3: host_env_rate[3] <= d_latch;
                endcase
            8'h04: case (host_ch)
                0: host_step[0][7:0] <= d_latch;
                1: host_step[1][7:0] <= d_latch;
                2: host_step[2][7:0] <= d_latch;
                3: host_step[3][7:0] <= d_latch;
                endcase
            8'h05: case (host_ch)
                0: host_step[0][15:8] <= d_latch;
                1: host_step[1][15:8] <= d_latch;
                2: host_step[2][15:8] <= d_latch;
                3: host_step[3][15:8] <= d_latch;
                endcase
            8'h06: begin
                spfm_pending <= 1;
                spfm_op <= 4'd1;
                spfm_ch <= host_ch;
                spfm_phase <= 0;
            end
            8'h07: begin
                spfm_pending <= 1;
                spfm_op <= 4'd2;
                spfm_ch <= host_ch;
            end
            default: ;
            endcase
        end

        // ---- SPFM 读 ----
        data_out <= 8'hFF;
        if (bus_rd) begin
            case (reg_addr)
            8'h00: data_out <= {5'b0, host_ch};
            8'h06: data_out <= {4'b0, ch_active};
            endcase
        end

        // ---- 微程序 ----
        if (sample_start) begin
            ustep <= 0;
            mix_sum <= 0;
        end else if (ustep < TOTAL_STEPS) begin
            case (ums)
            5'd0: begin
                // 读 phase_lo (设地址)
                ram_addr <= ch_base + {11'b0, O_PHASE_LO};
                ram_oe_n <= 0; ram_cs_n <= 0;
            end
            5'd1: begin
                // 锁存 phase_lo → acc_lo, 读 step_lo (设地址)
                acc_lo <= ram_io;
                ram_addr <= ch_base + {11'b0, O_STEP_LO};
                ram_oe_n <= 0; ram_cs_n <= 0;
            end
            5'd2: begin
                // 加法: acc_lo + step_lo, 写回 phase_lo
                {carry, acc_lo} <= {1'b0, acc_lo} + {1'b0, ram_io};
                ram_addr <= ch_base + {11'b0, O_PHASE_LO};
                ram_wdata <= acc_lo + ram_io;
                ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
            end
            5'd3: begin
                // 读 phase_hi (设地址)
                ram_addr <= ch_base + {11'b0, O_PHASE_HI};
                ram_oe_n <= 0; ram_cs_n <= 0;
            end
            5'd4: begin
                // 锁存 phase_hi → acc_hi, 读 step_hi (设地址)
                acc_hi <= ram_io;
                ram_addr <= ch_base + {11'b0, O_STEP_HI};
                ram_oe_n <= 0; ram_cs_n <= 0;
            end
            5'd5: begin
                // 加法: acc_hi + step_hi + carry, 写回 phase_hi
                {carry, acc_hi} <= {1'b0, acc_hi} + {1'b0, ram_io} + {8'b0, carry};
                ram_addr <= ch_base + {11'b0, O_PHASE_HI};
                ram_wdata <= acc_hi + ram_io + carry;
                ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
            end
            5'd6: begin
                // 读 level (设地址)
                ram_addr <= ch_base + {11'b0, O_LEVEL};
                ram_oe_n <= 0; ram_cs_n <= 0;
            end
            5'd7: begin
                // 锁存 level, 读 vol (设地址)
                level_r <= ram_io[3:0];
                ram_addr <= ch_base + {11'b0, O_VOL};
                ram_oe_n <= 0; ram_cs_n <= 0;
            end
            5'd8: begin
                // 锁存 vol, 读 wave_idx (设地址)
                vol_r <= ram_io[4:0];
                ram_addr <= ch_base + {11'b0, O_WAVE_IDX};
                ram_oe_n <= 0; ram_cs_n <= 0;
            end
            5'd9: begin
                // 锁存 wave_idx, 读 env_state (设地址)
                wave_idx_r <= ram_io[2:0];
                ram_addr <= ch_base + {11'b0, O_ENV_STATE};
                ram_oe_n <= 0; ram_cs_n <= 0;
            end
            5'd10: begin
                // 锁存 env_state, 如果活跃: 设 ROM 地址
                env_state_r <= ram_io[2:0];
                if (ram_io[2:0] != 0) begin
                    // phase[12:6] = {acc_hi[4:0], acc_lo[7:6]}
                    rom_addr <= {wave_idx_r, level_r, vol_r, acc_hi[4:0], acc_lo[7:6]};
                end
            end
            5'd11: begin
                // 锁存 ROM 输出, 累加到 mix_sum
                if (env_state_r != 0) begin
                    mix_sum <= mix_sum + $signed({1'b0, rom_data});
                end
            end
            5'd12: begin
                // 读 env_cnt (设地址)
                ram_addr <= ch_base + {11'b0, O_ENV_CNT};
                ram_oe_n <= 0; ram_cs_n <= 0;
            end
            5'd13: begin
                // 锁存 env_cnt, 读 env_rate (设地址)
                env_cnt_r <= ram_io;
                ram_addr <= ch_base + {11'b0, O_ENV_RATE};
                ram_oe_n <= 0; ram_cs_n <= 0;
            end
            5'd14: begin
                // 锁存 env_rate, 包络计算
                env_rate_r <= ram_io;
                if (env_state_r != 0) begin
                    if (env_cnt_r >= ram_io) begin
                        env_cnt_r <= 0;
                        case (env_state_r)
                        3'd1: begin
                            if (level_r < 15) level_r <= level_r + 1;
                            else env_state_r <= 3'd2;
                        end
                        3'd2: ; // sustain
                        3'd3: begin
                            if (level_r > 0) level_r <= level_r - 1;
                            else begin
                                level_r <= 0;
                                env_state_r <= 0;
                            end
                        end
                        default: ;
                        endcase
                    end else begin
                        env_cnt_r <= env_cnt_r + 1;
                    end
                end
            end
            5'd15: begin
                // 写回 env_state
                ram_addr <= ch_base + {11'b0, O_ENV_STATE};
                ram_wdata <= {5'b0, env_state_r};
                ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
            end
            5'd16: begin
                // 写回 level
                ram_addr <= ch_base + {11'b0, O_LEVEL};
                ram_wdata <= {4'b0, level_r};
                ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
            end
            5'd17: begin
                // 写回 env_cnt
                ram_addr <= ch_base + {11'b0, O_ENV_CNT};
                ram_wdata <= env_cnt_r;
                ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
                // 更新 ch_active shadow
                if (env_state_r == 0)
                    ch_active[uch] <= 0;
                else
                    ch_active[uch] <= 1;
            end
            5'd18: begin
                // 写 dac_out (调试用)
                ram_addr <= ch_base + {11'b0, O_DAC_OUT};
                if (env_state_r != 0)
                    ram_wdata <= rom_data;
                else
                    ram_wdata <= 0;
                ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
            end
            5'd19: begin
                // 空操作, 准备下一通道
            end
            endcase

            ustep <= ustep + 1;

            // 最后一步: 输出 DAC
            if (ustep == 8'd127) begin
                if (mix_sum > 127) mix_sum <= 127;
                if (mix_sum < -128) mix_sum <= -128;
                dac_out <= mix_sum[7:0];
            end
        end else begin
            // ---- 空闲期: 处理 SPFM 挂起操作 ----
            if (spfm_pending) begin
                case (spfm_op)
                4'd1: begin // note_on
                    case (spfm_phase)
                    4'd0: begin
                        ram_addr <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_PHASE_LO};
                        ram_wdata <= 0;
                        ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
                        spfm_phase <= 1;
                    end
                    4'd1: begin
                        ram_addr <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_PHASE_HI};
                        ram_wdata <= 0;
                        ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
                        spfm_phase <= 2;
                    end
                    4'd2: begin
                        ram_addr <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_STEP_LO};
                        case (spfm_ch)
                        0: ram_wdata <= host_step[0][7:0];
                        1: ram_wdata <= host_step[1][7:0];
                        2: ram_wdata <= host_step[2][7:0];
                        3: ram_wdata <= host_step[3][7:0];
                        endcase
                        ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
                        spfm_phase <= 3;
                    end
                    4'd3: begin
                        ram_addr <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_STEP_HI};
                        case (spfm_ch)
                        0: ram_wdata <= host_step[0][15:8];
                        1: ram_wdata <= host_step[1][15:8];
                        2: ram_wdata <= host_step[2][15:8];
                        3: ram_wdata <= host_step[3][15:8];
                        endcase
                        ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
                        spfm_phase <= 4;
                    end
                    4'd4: begin
                        ram_addr <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_LEVEL};
                        ram_wdata <= 0;
                        ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
                        spfm_phase <= 5;
                    end
                    4'd5: begin
                        ram_addr <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_ENV_STATE};
                        ram_wdata <= 8'd1; // attack
                        ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
                        spfm_phase <= 6;
                    end
                    4'd6: begin
                        ram_addr <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_ENV_CNT};
                        ram_wdata <= 0;
                        ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
                        spfm_phase <= 7;
                    end
                    4'd7: begin
                        ram_addr <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_VOL};
                        case (spfm_ch)
                        0: ram_wdata <= {3'b0, host_vol[0]};
                        1: ram_wdata <= {3'b0, host_vol[1]};
                        2: ram_wdata <= {3'b0, host_vol[2]};
                        3: ram_wdata <= {3'b0, host_vol[3]};
                        endcase
                        ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
                        spfm_phase <= 8;
                    end
                    4'd8: begin
                        ram_addr <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_WAVE_IDX};
                        case (spfm_ch)
                        0: ram_wdata <= {5'b0, host_wave_idx[0]};
                        1: ram_wdata <= {5'b0, host_wave_idx[1]};
                        2: ram_wdata <= {5'b0, host_wave_idx[2]};
                        3: ram_wdata <= {5'b0, host_wave_idx[3]};
                        endcase
                        ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
                        spfm_phase <= 9;
                    end
                    4'd9: begin
                        ram_addr <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_ENV_RATE};
                        case (spfm_ch)
                        0: ram_wdata <= host_env_rate[0];
                        1: ram_wdata <= host_env_rate[1];
                        2: ram_wdata <= host_env_rate[2];
                        3: ram_wdata <= host_env_rate[3];
                        endcase
                        ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
                        ch_active[spfm_ch] <= 1;
                        spfm_pending <= 0;
                    end
                    default: spfm_pending <= 0;
                    endcase
                end
                4'd2: begin // note_off: env_state = 3
                    ram_addr <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_ENV_STATE};
                    ram_wdata <= 8'd3;
                    ram_we_n <= 0; ram_cs_n <= 0; ram_drive_en <= 1;
                    spfm_pending <= 0;
                end
                default: spfm_pending <= 0;
                endcase
            end
        end
    end
end

endmodule
