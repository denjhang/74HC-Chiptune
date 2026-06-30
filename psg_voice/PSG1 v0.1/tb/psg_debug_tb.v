// psg_debug_tb.v — 打印 psg_voice 内部计数序列, 找 A5 频率错误根因
`timescale 1ns/1ps

module psg_debug_tb;

    reg clk = 0;
    always #4000 clk = ~clk;   // 125kHz

    reg        rst_n = 0;
    reg        period_we = 1'b1;
    reg  [7:0] period_in = 0;
    reg        gate = 1'b1;
    wire       wave_out;

    psg_voice u_dut (
        .clk(clk), .rst_n(rst_n),
        .period_we(period_we), .period_in(period_in),
        .gate(gate), .wave_out(wave_out)
    );

    // 探测内部信号
    wire [7:0] cnt = {u_dut.q_hi, u_dut.q_lo};
    wire       tc  = u_dut.tc_hi;
    wire       tog = u_dut.toggle_q;

    // 数 tc_hi 的上升沿 (应每次重装 1 个)
    reg tc_d;
    integer tc_rise;
    integer tog_rise;
    reg tog_d;

    integer i;
    initial begin
        tc_rise = 0; tog_rise = 0; tc_d = 0; tog_d = 0;
        #100 rst_n = 1'b1;
        @(negedge clk);
        period_in = 8'd185; period_we = 0;
        @(negedge clk); period_we = 1;

        // 等 400 个时钟进稳态, 然后测 2840 个时钟 (20个完整周期@71步)
        for (i = 0; i < 400; i = i + 1) @(posedge clk);
        tc_rise = 0; tog_rise = 0; tc_d = tc; tog_d = tog;
        for (i = 0; i < 2840; i = i + 1) begin
            @(posedge clk);
            #1;
            if (tc && !tc_d) tc_rise = tc_rise + 1;
            if (tog && !tog_d) tog_rise = tog_rise + 1;
            tc_d = tc; tog_d = tog;
        end
        $display("=== 2840 clk 内 (期望 40 个重装周期) ===");
        $display("tc_hi 上升沿: %0d (期望 ~40)", tc_rise);
        $display("toggle 上升沿: %0d (期望 ~20)", tog_rise);
        $display("=> 若 tc_rise > 40 说明 tc 有毛刺多触发");
        $finish;
    end

endmodule
