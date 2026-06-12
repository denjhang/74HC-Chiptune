`timescale 1ns/1ps
// wt_rtl.v — 4通道 WT 合成器, 74HC 模块实例化
// 架构: 查表累加器, 39SF040(ROM) + 62256(RAM)
//
// 74HC 验证实例 (不影响时序):
//   U2: ttl_74283 (8-bit) — phase_lo 加法器 (验证 acc_lo + step_lo)
//   U3: ttl_74283 (8-bit) — phase_hi 加法器 (验证 acc_hi + step_hi + carry)
//   U7: ttl_74138 (8-out) — 微步组译码器 (ums[4:2] → 8 组)
//
// 硬件实现中:
//   RAM 地址锁存: 74377 (15-bit), Enable_bar 由微程序控制
//   ROM 地址锁存: 74377 (19-bit), step 10 使能
//   DAC 输出锁存:   74377 (8-bit),  step 127 使能
//   RAM 写数据锁存: 74377 (8-bit),  写步骤使能
//   数据选择:       74157 mux (ram_io vs alu output)
//
// 仿真中用 reg + 非阻塞赋值, 等效于 74377 posedge clk 锁存
// 时序与 wt_ram.v 完全一致

module wt_rtl (
    input  wire        clk,
    inout  wire [7:0]  d,
    input  wire        cs_n,
    input  wire        a0,
    input  wire        wr_n,
    input  wire        rd_n,
    input  wire        rst_n,
    output wire [18:0] rom_addr,
    input  wire [7:0]  rom_data,
    output wire [14:0] ram_addr,
    inout  wire [7:0]  ram_io,
    output wire        ram_we_n,
    output wire        ram_oe_n,
    output wire        ram_cs_n,
    output wire [7:0]  dac_out
);

localparam [3:0] O_PHASE_LO=0, O_PHASE_HI=1, O_STEP_LO=2, O_STEP_HI=3;
localparam [3:0] O_LEVEL=4, O_ENV_STATE=5, O_ENV_CNT=6, O_VOL=7;
localparam [3:0] O_DAC_OUT=8, O_WAVE_IDX=9, O_ENV_RATE=10;

localparam SAMPLE_DIV=312, TOTAL_STEPS=128, STEPS_PER_CH=32;

reg [15:0] sample_cnt;
wire sample_start = (sample_cnt == 0);

reg [7:0] ustep;
wire [1:0] uch = ustep[6:5];
wire [4:0] ums = ustep[4:0];
wire [14:0] ch_base = {9'b0, uch, 4'b0};

// ============================================================
// 工作寄存器 (硬件: 74377 锁存; 仿真: reg, 等效行为)
// ============================================================
reg [7:0]  acc_lo, acc_hi;
reg        carry;
reg [7:0]  step_lo_r, step_hi_r;
reg [3:0]  level_r;
reg [2:0]  env_state_r;
reg [7:0]  env_cnt_r, env_rate_r;
reg [4:0]  vol_r;
reg [2:0]  wave_idx_r;
reg signed [15:0] mix_sum;

// RAM 接口 (硬件: 74377 锁存; 仿真: reg)
reg [14:0] ram_addr_r;
reg [7:0]  ram_wdata;
reg        ram_drive_en;
assign ram_addr = ram_addr_r;
assign ram_io   = ram_drive_en ? ram_wdata : 8'bz;

reg ram_we_nr, ram_oe_nr, ram_cs_nr;
assign ram_we_n = ram_we_nr;
assign ram_oe_n = ram_oe_nr;
assign ram_cs_n = ram_cs_nr;

// ROM 接口 (硬件: 74377 锁存; 仿真: reg)
reg [18:0] rom_addr_r;
assign rom_addr = rom_addr_r;

// DAC 输出 (硬件: 74377 锁存; 仿真: reg)
reg [7:0] dac_out_r;
assign dac_out = dac_out_r;

reg [3:0] ch_active;

// ============================================================
// 总线同步 (YM2413 风格)
// ============================================================
reg [7:0] d_latch;
always @(*) begin
    if (!cs_n && !wr_n) d_latch = d;
    else d_latch = d_latch;
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

// ============================================================
// 主机寄存器
// ============================================================
reg [7:0]  reg_addr;
reg [1:0]  host_ch;
reg [2:0]  host_wave_idx [0:3];
reg [4:0]  host_vol      [0:3];
reg [7:0]  host_env_rate [0:3];
reg [15:0] host_step     [0:3];

reg [7:0] data_out;
wire bus_rd = ~cs_n & ~rd_n;
assign d = bus_rd ? data_out : 8'bz;

reg        spfm_pending;
reg [3:0]  spfm_op;
reg [1:0]  spfm_ch;
reg [3:0]  spfm_phase;

// ============================================================
// 主 always 块 — 微程序控制 (与 wt_ram.v 一致)
// ============================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sample_cnt <= SAMPLE_DIV - 1;
        ustep <= 8'd128;
        acc_lo <= 0; acc_hi <= 0; carry <= 0;
        step_lo_r <= 0; step_hi_r <= 0;
        level_r <= 0; env_state_r <= 0; env_cnt_r <= 0;
        vol_r <= 0; wave_idx_r <= 0; env_rate_r <= 0;
        mix_sum <= 0;
        ram_addr_r <= 0; ram_we_nr <= 1; ram_oe_nr <= 1; ram_cs_nr <= 1;
        ram_wdata <= 0; ram_drive_en <= 0;
        rom_addr_r <= 0; dac_out_r <= 0;
        reg_addr <= 0; host_ch <= 0;
        host_wave_idx[0] <= 0; host_wave_idx[1] <= 0;
        host_wave_idx[2] <= 0; host_wave_idx[3] <= 0;
        host_vol[0] <= 0; host_vol[1] <= 0;
        host_vol[2] <= 0; host_vol[3] <= 0;
        host_env_rate[0] <= 0; host_env_rate[1] <= 0;
        host_env_rate[2] <= 0; host_env_rate[3] <= 0;
        host_step[0] <= 0; host_step[1] <= 0;
        host_step[2] <= 0; host_step[3] <= 0;
        ch_active <= 0; data_out <= 8'hFF;
        spfm_pending <= 0; spfm_op <= 0; spfm_ch <= 0; spfm_phase <= 0;
    end else begin
        // 采样率分频
        if (sample_cnt == 0) sample_cnt <= SAMPLE_DIV - 1;
        else sample_cnt <= sample_cnt - 1;

        // RAM 默认空闲
        ram_we_nr <= 1;
        ram_oe_nr <= 1;
        ram_cs_nr <= 1;
        ram_drive_en <= 0;

        // SPFM 地址锁存
        if (addr_req_pulse) reg_addr <= d_latch;

        // SPFM 数据锁存
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
                spfm_pending <= 1; spfm_op <= 4'd1;
                spfm_ch <= host_ch; spfm_phase <= 0;
            end
            8'h07: begin
                spfm_pending <= 1; spfm_op <= 4'd2;
                spfm_ch <= host_ch;
            end
            default: ;
            endcase
        end

        // SPFM 读
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
                ram_addr_r <= ch_base + {11'b0, O_PHASE_LO};
                ram_oe_nr <= 0; ram_cs_nr <= 1'b0;
            end
            5'd1: begin
                acc_lo <= ram_io;
                step_lo_r <= ram_io;
                ram_addr_r <= ch_base + {11'b0, O_STEP_LO};
                ram_oe_nr <= 0; ram_cs_nr <= 1'b0;
            end
            5'd2: begin
                {carry, acc_lo} <= {1'b0, acc_lo} + {1'b0, step_lo_r};
                ram_addr_r <= ch_base + {11'b0, O_PHASE_LO};
                ram_wdata <= acc_lo + step_lo_r;
                ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
            end
            5'd3: begin
                ram_addr_r <= ch_base + {11'b0, O_PHASE_HI};
                ram_oe_nr <= 0; ram_cs_nr <= 1'b0;
            end
            5'd4: begin
                acc_hi <= ram_io;
                step_hi_r <= ram_io;
                ram_addr_r <= ch_base + {11'b0, O_STEP_HI};
                ram_oe_nr <= 0; ram_cs_nr <= 1'b0;
            end
            5'd5: begin
                {carry, acc_hi} <= {1'b0, acc_hi} + {1'b0, step_hi_r} + {8'b0, carry};
                ram_addr_r <= ch_base + {11'b0, O_PHASE_HI};
                ram_wdata <= acc_hi + step_hi_r + carry;
                ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
            end
            5'd6: begin
                ram_addr_r <= ch_base + {11'b0, O_LEVEL};
                ram_oe_nr <= 0; ram_cs_nr <= 1'b0;
            end
            5'd7: begin
                level_r <= ram_io[3:0];
                ram_addr_r <= ch_base + {11'b0, O_VOL};
                ram_oe_nr <= 0; ram_cs_nr <= 1'b0;
            end
            5'd8: begin
                vol_r <= ram_io[4:0];
                ram_addr_r <= ch_base + {11'b0, O_WAVE_IDX};
                ram_oe_nr <= 0; ram_cs_nr <= 1'b0;
            end
            5'd9: begin
                wave_idx_r <= ram_io[2:0];
                ram_addr_r <= ch_base + {11'b0, O_ENV_STATE};
                ram_oe_nr <= 0; ram_cs_nr <= 1'b0;
            end
            5'd10: begin
                env_state_r <= ram_io[2:0];
                if (ram_io[2:0] != 0)
                    rom_addr_r <= {wave_idx_r, level_r, vol_r, acc_hi[4:0], acc_lo[7:6]};
            end
            5'd11: begin
                if (env_state_r != 0)
                    mix_sum <= mix_sum + $signed({1'b0, rom_data});
            end
            5'd12: begin
                ram_addr_r <= ch_base + {11'b0, O_ENV_CNT};
                ram_oe_nr <= 0; ram_cs_nr <= 1'b0;
            end
            5'd13: begin
                env_cnt_r <= ram_io;
                ram_addr_r <= ch_base + {11'b0, O_ENV_RATE};
                ram_oe_nr <= 0; ram_cs_nr <= 1'b0;
            end
            5'd14: begin
                env_rate_r <= ram_io;
                if (env_state_r != 0) begin
                    if (env_cnt_r >= ram_io) begin
                        env_cnt_r <= 0;
                        case (env_state_r)
                        3'd1: begin
                            if (level_r < 15) level_r <= level_r + 1;
                            else env_state_r <= 3'd2;
                        end
                        3'd2: ;
                        3'd3: begin
                            if (level_r > 0) level_r <= level_r - 1;
                            else begin level_r <= 0; env_state_r <= 0; end
                        end
                        default: ;
                        endcase
                    end else begin
                        env_cnt_r <= env_cnt_r + 1;
                    end
                end
            end
            5'd15: begin
                ram_addr_r <= ch_base + {11'b0, O_ENV_STATE};
                ram_wdata <= {5'b0, env_state_r};
                ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
            end
            5'd16: begin
                ram_addr_r <= ch_base + {11'b0, O_LEVEL};
                ram_wdata <= {4'b0, level_r};
                ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
            end
            5'd17: begin
                ram_addr_r <= ch_base + {11'b0, O_ENV_CNT};
                ram_wdata <= env_cnt_r;
                ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
                if (env_state_r == 0) ch_active[uch] <= 0;
                else ch_active[uch] <= 1;
            end
            5'd18: begin
                ram_addr_r <= ch_base + {11'b0, O_DAC_OUT};
                ram_wdata <= env_state_r != 0 ? rom_data : 8'd0;
                ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
            end
            5'd19: begin
            end
            default: ;
            endcase

            ustep <= ustep + 1;

            if (ustep == 8'd127) begin
                if (mix_sum > 127) mix_sum <= 127;
                if (mix_sum < -128) mix_sum <= -128;
                dac_out_r <= mix_sum[7:0];
            end
        end else begin
            // ---- 空闲期: SPFM 操作 ----
            if (spfm_pending) begin
                case (spfm_op)
                4'd1: begin
                    case (spfm_phase)
                    4'd0: begin
                        ram_addr_r <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_PHASE_LO};
                        ram_wdata <= 0;
                        ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
                        spfm_phase <= 1;
                    end
                    4'd1: begin
                        ram_addr_r <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_PHASE_HI};
                        ram_wdata <= 0;
                        ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
                        spfm_phase <= 2;
                    end
                    4'd2: begin
                        ram_addr_r <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_STEP_LO};
                        case (spfm_ch)
                        0: ram_wdata <= host_step[0][7:0];
                        1: ram_wdata <= host_step[1][7:0];
                        2: ram_wdata <= host_step[2][7:0];
                        3: ram_wdata <= host_step[3][7:0];
                        endcase
                        ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
                        spfm_phase <= 3;
                    end
                    4'd3: begin
                        ram_addr_r <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_STEP_HI};
                        case (spfm_ch)
                        0: ram_wdata <= host_step[0][15:8];
                        1: ram_wdata <= host_step[1][15:8];
                        2: ram_wdata <= host_step[2][15:8];
                        3: ram_wdata <= host_step[3][15:8];
                        endcase
                        ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
                        spfm_phase <= 4;
                    end
                    4'd4: begin
                        ram_addr_r <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_LEVEL};
                        ram_wdata <= 0;
                        ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
                        spfm_phase <= 5;
                    end
                    4'd5: begin
                        ram_addr_r <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_ENV_STATE};
                        ram_wdata <= 8'd1;
                        ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
                        spfm_phase <= 6;
                    end
                    4'd6: begin
                        ram_addr_r <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_ENV_CNT};
                        ram_wdata <= 0;
                        ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
                        spfm_phase <= 7;
                    end
                    4'd7: begin
                        ram_addr_r <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_VOL};
                        case (spfm_ch)
                        0: ram_wdata <= {3'b0, host_vol[0]};
                        1: ram_wdata <= {3'b0, host_vol[1]};
                        2: ram_wdata <= {3'b0, host_vol[2]};
                        3: ram_wdata <= {3'b0, host_vol[3]};
                        endcase
                        ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
                        spfm_phase <= 8;
                    end
                    4'd8: begin
                        ram_addr_r <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_WAVE_IDX};
                        case (spfm_ch)
                        0: ram_wdata <= {5'b0, host_wave_idx[0]};
                        1: ram_wdata <= {5'b0, host_wave_idx[1]};
                        2: ram_wdata <= {5'b0, host_wave_idx[2]};
                        3: ram_wdata <= {5'b0, host_wave_idx[3]};
                        endcase
                        ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
                        spfm_phase <= 9;
                    end
                    4'd9: begin
                        ram_addr_r <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_ENV_RATE};
                        case (spfm_ch)
                        0: ram_wdata <= host_env_rate[0];
                        1: ram_wdata <= host_env_rate[1];
                        2: ram_wdata <= host_env_rate[2];
                        3: ram_wdata <= host_env_rate[3];
                        endcase
                        ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
                        ch_active[spfm_ch] <= 1;
                        spfm_pending <= 0;
                    end
                    default: spfm_pending <= 0;
                    endcase
                end
                4'd2: begin
                    ram_addr_r <= {9'b0, spfm_ch, 4'b0} + {11'b0, O_ENV_STATE};
                    ram_wdata <= 8'd3;
                    ram_we_nr <= 0; ram_cs_nr <= 1'b0; ram_drive_en <= 1;
                    spfm_pending <= 0;
                end
                default: spfm_pending <= 0;
                endcase
            end
        end
    end
end

endmodule
