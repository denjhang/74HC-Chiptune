`timescale 1ns/1ps

// wsg3_core_v2.v — WSG3 重新设计 (基于 62256 SRAM)
//
// 核心改进：用 CY62256 替代 LS189，直接存储 16-bit 相位值
// 简化 TDM：每通道 4 步 (读lo+读hi+加+写+输出)
//
// 内存布局 (62256 地址空间):
//   0x00: ch0 phase_lo
//   0x01: ch0 phase_hi
//   0x02: ch0 freq_lo
//   0x03: ch0 freq_hi
//   0x04: ch0 wave (bit[2:0]) + vol (bit[6:4])
//   0x05-0x09: ch1 同上
//   0x0A-0x0E: ch2 同上
//
// TDM 步骤 (简化为 12 步):
//   Step 0: ch0 读 phase_lo
//   Step 1: ch0 读 phase_hi, 16-bit 加法, 锁存结果
//   Step 2: ch0 写 phase_lo+hi, 输出
//   Step 3-5: ch1 同上
//   Step 6-8: ch2 同上
//   Step 9-11: 空闲 (SPFM 可写)

module wsg3_core_v2 (
    input  wire        SPFM_CLK,
    input  wire        SPFM_RST_n,
    input  wire [7:0]  SPFM_D,
    input  wire        SPFM_A0,
    input  wire        SPFM_CS_n,
    input  wire        SPFM_WR_n,
    input  wire        SPFM_RD_n,
    output wire [7:0]  dac_out
);

    // ============================================================
    // HCNT 6-bit 计数器 (96kHz TDM)
    // ============================================================
    reg [5:0] hcnt_r;
    always @(posedge SPFM_CLK or negedge SPFM_RST_n) begin
        if (!SPFM_RST_n)
            hcnt_r <= 6'b0;
        else
            hcnt_r <= hcnt_r + 1'b1;
    end

    wire [2:0] tdm_step = hcnt_r[5:3];  // 0-7 (足够 3 通道)

    // ============================================================
    // CY62256 SRAM 接口
    // ============================================================
    wire [7:0]  sram_addr;
    wire [7:0]  sram_din;
    wire [7:0]  sram_dout;
    wire        sram_we_n;
    wire        sram_oe_n;

    // TDM 地址生成
    reg [7:0] sram_addr_tdm;
    always @(*) begin
        case (tdm_step)
            3'd0: sram_addr_tdm = 8'h00;  // ch0 phase_lo
            3'd1: sram_addr_tdm = 8'h01;  // ch0 phase_hi
            3'd2: sram_addr_tdm = 8'h04;  // ch0 wave/vol (输出时读)
            3'd3: sram_addr_tdm = 8'h05;  // ch1 phase_lo
            3'd4: sram_addr_tdm = 8'h06;  // ch1 phase_hi
            3'd5: sram_addr_tdm = 8'h09;  // ch1 wave/vol
            3'd6: sram_addr_tdm = 8'h0A;  // ch2 phase_lo
            3'd7: sram_addr_tdm = 8'h0B;  // ch2 phase_hi
            default: sram_addr_tdm = 8'h0E;  // ch2 wave/vol
        endcase
    end

    // SPFM 写优先于 TDM
    assign sram_addr = (SPFM_CS_n == 1'b0 && SPFM_A0 == 1'b0) ? {4'h0, SPFM_D[3:0], SPFM_D[7:4]} : sram_addr_tdm;
    assign sram_din   = SPFM_D;
    assign sram_we_n = (SPFM_CS_n == 1'b0 && SPFM_WR_n == 1'b0 && SPFM_A0 == 1'b1) ? 1'b0 : 1'b1;  // SPFM 写
    assign sram_oe_n  = 1'b0;  // 始终使能输出

    // CY62256 模型 (简化版，实际需要完整模型)
    reg [7:0] sram_mem[0:255];
    always @(posedge SPFM_CLK or negedge SPFM_RST_n) begin
        if (!SPFM_RST_n) begin
            // 初始化
        end else if (sram_we_n == 1'b0) begin
            sram_mem[sram_addr] <= sram_din;
        end
    end
    assign sram_dout = sram_mem[sram_addr];

    // ============================================================
    // 16-bit 相位累加器 (简化版)
    // ============================================================
    reg [15:0] phase_acc;
    reg [15:0] freq;
    reg [2:0]  wave;
    reg [3:0]  vol;

    // TDM 状态机
    always @(posedge SPFM_CLK or negedge SPFM_RST_n) begin
        if (!SPFM_RST_n) begin
            phase_acc <= 16'b0;
        end else begin
            case (tdm_step)
                3'd0: begin
                    // 读 phase_lo (锁存)
                end
                3'd1: begin
                    // 读 phase_hi + 加法
                    phase_acc <= phase_acc + freq;  // 简化，实际需要分步骤
                end
                3'd2: begin
                    // 写回 + 输出
                end
                // ... 其他通道
            endcase
        end
    end

    // TODO: 完整实现
    assign dac_out = 8'h00;

endmodule
