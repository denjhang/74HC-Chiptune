// psg_v02_debug.v — 调试 period/vol 写入 + 振荡
`timescale 1ns/1ps

module psg_v02_debug;

    reg clk = 0;
    localparam CLK_HZ = 64000;
    always #(1_000_000_000/(2*CLK_HZ)) clk = ~clk;

    reg rst_n = 0, period_le = 0, A0 = 0;
    reg [7:0] data = 0;
    wire [7:0] audio_out;

    psg_voice_v02 u_dut (.clk(clk),.rst_n(rst_n),.period_le(period_le),.A0(A0),.data(data),.audio_out(audio_out));

    // 探测内部
    wire [7:0] pq = u_dut.period_q;
    wire [3:0] vol = u_dut.vol;
    wire tc_hi = u_dut.tc_hi;
    wire rp = u_dut.reload_pulse;
    wire tq = u_dut.toggle_q;

    task wr_period; input [7:0] p; begin data=p; #200; period_le=1; #500; period_le=0; #200; end endtask
    task wr_vol; input [3:0] v; begin data={4'b0,v}; #200; A0=1; #500; A0=0; #200; end endtask

    integer i;
    initial begin
        #500 rst_n = 1;
        @(negedge clk);
        wr_period(183);   // A4
        wr_vol(15);       // 满音量

        // 跳过前 250 周期(等计数器首次到 0xFF), 再看 tc_hi/toggle
        for (i = 0; i < 250; i = i + 1) @(posedge clk);
        $display("\n=== 跳过 250 clk (等计数器到 0xFF), 看 tc/toggle/audio ===");
        $display("clk | tc_hi reload toggle audio");
        for (i = 0; i < 80; i = i + 1) begin
            @(posedge clk); #1;
            $display("%0d  | %0d   %0d   %0d   %0d", i, tc_hi, rp, tq, audio_out);
        end
        $finish;
    end
    initial begin #2_000_000_000; $finish; end
endmodule
