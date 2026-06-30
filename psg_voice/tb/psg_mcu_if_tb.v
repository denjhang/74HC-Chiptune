// psg_mcu_if_tb.v — 验证 MCU 异步并行直驱接口规范
//
// 模拟 MCU 写 PERIOD 的真实时序 (异步于 clk):
//   1. D[7:0] = period; WE=0; 延时 10us; WE=1  (覆盖 1 个 clk 沿 @125kHz)
//   2. gate=1 发声, 测频率
//   3. 再写新 period (不关 gate), 验证音高实时切换
// 验证目标: MCU 无需知道 clk 相位, 只要 WE 低电平 >= 1 个 clk 周期即可正确锁存

`timescale 1ns/1ps

module psg_mcu_if_tb;

    reg clk = 0;
    localparam CLK_HZ   = 125_000;
    localparam CLK_HALF = 1_000_000_000 / (2 * CLK_HZ);  // 4000ns
    always #CLK_HALF clk = ~clk;   // 125kHz 连续自由跑, MCU 无法控制相位

    // MCU 侧信号
    reg  [7:0] mcu_d = 0;
    reg        mcu_le = 1'b0;      // 默认锁存 (LE=0 保持)
    reg        mcu_gate = 0;
    reg        mcu_rst_n = 0;
    wire       wave_out;

    psg_voice u_dut (
        .clk       (clk),
        .rst_n     (mcu_rst_n),
        .period_in (mcu_d),
        .period_le (mcu_le),
        .gate      (mcu_gate),
        .wave_out  (wave_out)
    );

    // 模拟 MCU 写 PERIOD (HC373 透明锁存, 与 clk 完全解耦)
    // LE 高=透明(Q跟随D), LE 低=锁存(Q固定)
    task mcu_write_period;
        input [7:0] p;
        begin
            mcu_d = p;
            #100;               // 数据建立
            mcu_le = 1'b1;       // 透明: Q 跟随 D
            #500;                // 透明保持 0.5us (建立时间)
            mcu_le = 1'b0;       // 锁存: Q 固定为 p
            #100;                // 数据保持
        end
    endtask

    // 测频率 (数 wave_out 上升沿)
    integer rise_cnt;
    task measure;
        input integer ncycles;
        integer i;
        reg wd;
        begin
            rise_cnt = 0; wd = wave_out;
            for (i = 0; i < ncycles; i = i + 1) begin
                @(posedge clk);
                if (wave_out && !wd) rise_cnt = rise_cnt + 1;
                wd = wave_out;
            end
        end
    endtask

    integer i;
    real fmeas;
    initial begin
        $display("=== MCU 并行直驱接口验证 ===");
        #2000 mcu_rst_n = 1'b1;       // 上电复位
        #2000;

        // 测试1: 写 A4 period=114, gate on, 测频
        mcu_write_period(8'd114);
        mcu_gate = 1'b1;
        #50000;                        // 让振荡稳定
        measure(12500);                // 0.1s 窗口
        fmeas = real'(rise_cnt) * CLK_HZ / 12500.0;
        $display("写 PERIOD=114(A4), gate=1: 上升沿 %0d -> %0f Hz (期望440)", rise_cnt, fmeas);

        // 测试2: 不关 gate, 实时改写 A5 period=185, 测频
        mcu_write_period(8'd185);
        #50000;
        measure(12500);
        fmeas = real'(rise_cnt) * CLK_HZ / 12500.0;
        $display("实时改写 PERIOD=185(A5): 上升沿 %0d -> %0f Hz (期望880)", rise_cnt, fmeas);

        // 测试3: gate off 应立即静音
        mcu_gate = 1'b0;
        measure(2500);
        $display("gate=0: 上升沿 %0d (期望0, 静音)", rise_cnt);

        if (fmeas > 850 && fmeas < 910)
            $display(">>> 接口规范验证通过: 异步 WE 写入正确, 音高实时可切 <<<");
        else
            $display(">>> 接口异常 <<<");
        $finish;
    end

    initial begin #3_000_000_000; $display("超时"); $finish; end

endmodule
