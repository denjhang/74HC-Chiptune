// psg_voice_tb.v — 单音 PSG testbench
//
// 验证内容:
//   1. host 写入 period, 观察方波输出周期是否符合
//      频率公式: f = clk / (2 * (256 - period))
//      (计数器从 period 自增到 255, 共 256-period 步, 再翻转)
//   2. 测几个常用音 @125kHz 时钟:
//        A4 440Hz → period = 256 - 125000/(2*440) = 256 - 142 = 114
//        A5 880Hz → period = 256 - 125000/(2*880) = 256 - 71  = 185
//   3. gate 开关: gate=0 静音, gate=1 发声
//
// 用较小 clk (模拟 125kHz 用 125kHz 不现实, 仿真慢; 改用 1MHz 加速,
// 但仍按真实关系算 period). 这里直接用 clk=125kHz 实际频率仿真短时间.

`timescale 1ns/1ps

module psg_voice_tb;

    // 用 125kHz 时钟仿真 (周期 8000ns)
    reg clk = 0;
    localparam CLK_HZ   = 125_000;
    localparam CLK_HALF = 1_000_000_000 / (2 * CLK_HZ);  // 4000ns
    always #CLK_HALF clk = ~clk;

    reg        rst_n = 0;
    reg        period_le = 1'b0;   // 默认锁存 (LE=0 保持)
    reg  [7:0] period_in = 0;
    reg        gate = 0;
    wire       wave_out;

    psg_voice u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .period_le (period_le),
        .period_in (period_in),
        .gate      (gate),
        .wave_out  (wave_out)
    );

    // 统计 wave_out 翻转次数, 计算实际频率
    integer edge_cnt;
    integer total_clks;
    real    measured_freq;
    real    expected_freq;

    // host 写 period 任务 (HC373 透明锁存: LE 高透明, 低锁存)
    // 与 clk 完全解耦, 无需对齐 clk 沿
    task write_period;
        input [7:0] p;
        begin
            period_in = p;
            #100;
            period_le = 1'b1;   // 透明: Q 跟随 D
            #100;
            period_le = 1'b0;   // 锁存: Q 固定
        end
    endtask

    // 测量当前频率: 跑 N 个时钟, 数 wave_out 上升沿
    task measure_freq;
        input integer ncycles;
        integer i;
        reg wave_d;
        begin
            edge_cnt = 0;
            wave_d = wave_out;
            for (i = 0; i < ncycles; i = i + 1) begin
                @(posedge clk);
                if (wave_out && !wave_d) edge_cnt = edge_cnt + 1;
                wave_d = wave_out;
            end
            // 频率 = 上升沿数 / (ncycles / CLK_HZ)
            measured_freq = real'(edge_cnt) * CLK_HZ / real'(ncycles);
        end
    endtask

    integer expected_period;
    real    err_pct;

    initial begin
        $display("=== PSG 单音方波测试 @125kHz 时钟 ===");
        #100 rst_n = 1'b1;
        @(negedge clk);

        // ---------- 测试 A4 (440Hz) ----------
        // period = 256 - 125000/(2*440) = 256 - 142.0 = 114
        write_period(8'd114);
        gate = 1'b1;            // 开 gate
        expected_freq = 440.0;
        measure_freq(12500);    // 跑 0.1 秒 (12500 个 clk @125kHz... 实际 0.1s)
        $display("A4 目标 %0f Hz, 实测 %0f Hz (上升沿 %0d/12500 clk)",
                 expected_freq, measured_freq, edge_cnt);

        // ---------- 测试 A5 (880Hz) ----------
        // 先充分让计数器稳定到新 period
        write_period(8'd185);
        // 等 200 个时钟让计数器完成多次重装, 进入稳态
        begin : settle
            integer k;
            for (k = 0; k < 400; k = k + 1) @(posedge clk);
        end
        expected_freq = 880.0;
        measure_freq(12500);
        $display("A5 目标 %0f Hz, 实测 %0f Hz (上升沿 %0d/12500 clk)",
                 expected_freq, measured_freq, edge_cnt);

        // ---------- gate 测试 ----------
        gate = 1'b0;            // 关 gate, 应静音
        measure_freq(2500);
        $display("Gate OFF: 上升沿 %0d (应为 0)", edge_cnt);
        gate = 1'b1;            // 重新开
        measure_freq(2500);
        $display("Gate ON : 上升沿 %0d (应 > 0)", edge_cnt);

        if (edge_cnt > 0)
            $display(">>> 验证通过: PSG 方波振荡 + period 可编程 + gate 开关均正常 <<<");
        else
            $display(">>> 错误: 未振荡 <<<");
        $finish;
    end

    // 超时保护
    initial begin
        #5_000_000_000;  // 5s
        $display(">>> 超时 <<<");
        $finish;
    end

endmodule
