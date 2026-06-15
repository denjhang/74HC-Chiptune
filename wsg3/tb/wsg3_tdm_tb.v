// wsg3_tdm_tb.v — TDM + 相位累加器测试

`timescale 1ns/1ps

module wsg3_tdm_tb;
    reg CLK, RST_n;
    reg [7:0] u11_dq;
    reg [7:0] u10_dq;

    wire [3:0] step;
    wire sel_2l, sel_2k, latch_phase;
    wire [7:0] phase_acc;

    // TDM 模块
    wsg3_tdm u_tdm (
        .CLK(CLK),
        .RST_n(RST_n),
        .step(step),
        .sel_2l(sel_2l),
        .sel_2k(sel_2k),
        .latch_phase(latch_phase)
    );

    // 相位累加器模块
    wsg3_phase_acc u_phase (
        .CLK(CLK),
        .RST_n(RST_n),
        .u11_dq(u11_dq),
        .u10_dq(u10_dq),
        .sel_2l(sel_2l),
        .sel_2k(sel_2k),
        .latch_phase(latch_phase),
        .phase_acc(phase_acc)
    );

    // 时钟 3.072MHz
    initial CLK = 0;
    always #162.5 CLK = ~CLK;

    initial begin
        $display("=== WSG3 TDM + Phase Acc Test ===");
        RST_n = 0;
        u11_dq = 8'h00;
        u10_dq = 8'h00;

        #100;
        RST_n = 1;
        #1000;

        // 测试: u10_dq = 1 (频率字), u11_dq = 0 (初始相位)
        u10_dq = 8'h01;
        u11_dq = 8'h00;

        #10000;

        $display("After 10us: step=%d, phase_acc=0x%02X", step, phase_acc);
        $display("=== Test Complete ===");
        $finish;
    end

endmodule
