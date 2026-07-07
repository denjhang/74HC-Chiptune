// psg3_top_tb.v — PSG3 v0.4 顶层验证 (总线挂方波+噪音两通道)
//
// 验证目标:
//   1. 总线写 reg0(period)+reg1(控制) → 方波通道出声, 频率正确
//   2. 总线写 reg6(噪音控制) → 噪音通道出声
//   3. 两通道同时工作互不干扰
//
// 频率校验 (方波, 64kHz):
//   period=183 → 方波周期 = 2×(256-183) = 146 clk → f = 64000/146 ≈ 438Hz (A4)
//   toggle 在每个 reload_pulse 上升沿翻转, reload_pulse 频率 = TC 频率 = 64000/(256-183) = 876Hz
//   q1 (toggle) 周期 = 2×reload_pulse 周期 → q1 频率 = 876/2 = 438Hz ✅

`timescale 1ns/1ps

module psg3_top_tb;

    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    reg  [7:0] bus_data = 8'h00;
    reg        A0 = 1'b0;
    reg        WR_n = 1'b1;
    reg        CS_n = 1'b1;

    wire [7:0] sq_audio, nz_audio;
    wire       tc_out;

    psg3_top u_dut (
        .clk(clk), .rst_n(rst_n),
        .bus_data(bus_data), .A0(A0), .WR_n(WR_n), .CS_n(CS_n),
        .sq_audio(sq_audio), .nz_audio(nz_audio), .tc_out(tc_out)
    );

    // 64kHz 时钟 (周期 ~15.625μs, 这里用 15625ns 方便整数)
    always #7812 clk = ~clk;

    initial begin
        $dumpfile("psg3_top.vcd");
        $dumpvars(0, psg3_top_tb);
    end

    // ====== 总线写任务 (完整事务: /CS 包两拍) ======
    task bus_write;
        input [7:0] addr;   // 独热码地址
        input [7:0] data;
        begin
            @(posedge clk); #1;
            CS_n = 1'b0;                    // 事务开始
            // 第 1 拍: 写地址
            bus_data = addr; A0 = 1'b0;
            #2;
            WR_n = 1'b0; #2; WR_n = 1'b1;   // /WR 脉冲锁地址
            #2;
            // 第 2 拍: 写数据
            bus_data = data; A0 = 1'b1;
            #2;
            WR_n = 1'b0; #2; WR_n = 1'b1;   // /WR 脉冲锁数据
            #2;
            CS_n = 1'b1;                    // 事务结束
            bus_data = 8'h00; A0 = 1'b0;
        end
    endtask

    // ====== 方波频率测量 ======
    integer sq_rising = 0;     // sq_audio 非零→零不算, 数 sq_audio 从 0 变非零的次数
    integer sq_last_nz = 0;
    integer nz_nz_count = 0;   // 噪音非零采样数

    // 监测方波: sq_audio != 0 视为高电平, 数上升沿
    always @(posedge clk) begin
        if (sq_audio != 0 && sq_last_nz == 0) sq_rising = sq_rising + 1;
        sq_last_nz = (sq_audio != 0) ? 1 : 0;
        if (nz_audio != 0) nz_nz_count = nz_nz_count + 1;
    end

    // ====== 主测试 ======
    integer errors = 0;
    integer i;
    reg [7:0] audio_samples[0:7];  // 保存方波采样看波形
    initial begin
        // 复位
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ====== 测试 1: 方波通道 (CH0) ======
        $display("=== Test 1: Square CH0, period=183 (A4~438Hz), duty50, vol15 ===");
        // 独热码地址: reg0=0x01 (period), reg1=0x02 (控制)
        bus_write(8'h01, 8'd183);                    // reg0 = period = 183
        bus_write(8'h02, 8'b1100_1111);              // reg1 = vol15 | duty50(00) | mode方波(0) | ref(0)
        // 0xCF = vol=15, duty=00(50%), mode=0, ref=0

        // 跑 3000 个 clk (~46ms), 数方波上升沿
        sq_rising = 0;
        repeat (3000) @(posedge clk);
        // 期望: 438Hz × 0.046s ≈ 20 个上升沿 (周期 146 clk, 3000 clk ≈ 20.5 周期)
        $display("  square rising edges: %0d / 3000 clk (expect ~20)", sq_rising);
        $display("  sq_audio peak: %0d (expect 240 = vol15<<4)", sq_audio);
        if (sq_rising >= 18 && sq_rising <= 22) $display("  PASS: square freq OK (~438Hz)");
        else begin $display("  FAIL: square freq wrong, edges %0d", sq_rising); errors = errors + 1; end

        // ====== 测试 2: 占空比切换 (25%, 频率应减半 ~219Hz) ======
        $display("=== Test 2: duty 25pct, freq should halve ===");
        bus_write(8'h02, 8'b1101_1111);  // duty=01(25%), vol15
        sq_rising = 0;
        repeat (3000) @(posedge clk);
        $display("  square rising edges: %0d (expect ~10, duty25 halve)", sq_rising);
        if (sq_rising >= 8 && sq_rising <= 12) $display("  PASS: duty25 freq halved");
        else begin $display("  FAIL: duty switch wrong"); errors = errors + 1; end

        // ====== 测试 3: 噪音通道 (CH1) ======
        $display("=== Test 3: Noise CH1, freq div4, vol15 ===");
        // reg6=0x40 (独热码). 控制: vol15 | freq÷4(01) | 不绑定(0)
        bus_write(8'h40, 8'b0101_1111);  // vol=15, freq_sel=01(div4), bind=0
        nz_nz_count = 0;
        repeat (3000) @(posedge clk);
        $display("  noise nonzero samples: %0d / 3000 clk (expect >100 = audible)", nz_nz_count);
        if (nz_nz_count > 100) $display("  PASS: noise channel audible");
        else begin $display("  FAIL: noise channel silent"); errors = errors + 1; end

        // ====== 测试 4: 两通道同时工作 (方波恢复50% + 噪音继续) ======
        $display("=== Test 4: both channels, no interference ===");
        bus_write(8'h02, 8'b1100_1111);  // 方波恢复 duty50 vol15
        sq_rising = 0; nz_nz_count = 0;
        repeat (3000) @(posedge clk);
        $display("  square edges: %0d, noise nonzero: %0d", sq_rising, nz_nz_count);
        if (sq_rising >= 18 && nz_nz_count > 100) $display("  PASS: both channels work together");
        else begin $display("  FAIL: channels interfere"); errors = errors + 1; end

        // ====== 测试 5: 方波静音 (vol=0) ======
        $display("=== Test 5: square vol=0 should mute ===");
        bus_write(8'h02, 8'b1100_0000);  // vol=0, duty50
        sq_rising = 0;
        repeat (1000) @(posedge clk);
        if (sq_rising == 0) $display("  PASS: vol=0 muted");
        else begin $display("  FAIL: vol=0 still output"); errors = errors + 1; end

        $display("=====");
        $display("Total errors: %0d", errors);
        if (errors == 0) $display("SUCCESS: PSG3 square+noise 2ch on bus verified");
        else             $display("WARNING: errors need fix");
        $finish;
    end

endmodule
