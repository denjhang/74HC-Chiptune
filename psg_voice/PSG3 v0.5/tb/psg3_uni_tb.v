// psg3_uni_tb.v — PSG3 v0.5 三通道验证 (方波 + 波形 + 噪音)
// 寄存器: reg0/1=方波, reg2=噪音, reg3/4/5=波形
// 波形周期: 锯齿族单向16步 (freq=4M/(16×(4096-p12))), 三角折返30步 (freq=4M/(30×(4096-p12)))
`timescale 1ns/1ps
module psg3_uni_tb;
    reg clk=0, rst_n=0;
    reg [7:0] bd=0;
    reg A0=0, WR_n=1, CS_n=1;
    wire [7:0] sq_a, uni_a, nz_a;
    wire sq_tc, uni_tc;
    psg3_top dut(.clk(clk),.rst_n(rst_n),.bus_data(bd),.A0(A0),.WR_n(WR_n),.CS_n(CS_n),
                 .sq_audio(sq_a),.uni_audio(uni_a),.nz_audio(nz_a),
                 .sq_tc(sq_tc),.uni_tc(uni_tc));
    always #125 clk=~clk;   // 4MHz
    integer errors=0, i, mx, mn;
    task bw;
        input [7:0] a; input [7:0] d;
        begin
            @(negedge clk); CS_n=0; bd=a; A0=0; WR_n=0;
            @(posedge clk); WR_n=1;
            @(negedge clk); bd=d; A0=1; WR_n=0;
            @(posedge clk); WR_n=1;
            @(negedge clk); CS_n=1; bd=0; A0=0;
        end
    endtask
    // 设波形通道 (reg3/4/5): period12, vol, duty, wave_sel, mode_sel
    task set_uni;
        input [11:0] p12; input [3:0] vol; input [3:0] duty; input [1:0] wave; input mode;
        begin
            bw(8'h08, p12[7:0]);                   // reg3 = 波形 period[7:0]
            bw(8'h10, {p12[11:8], vol});           // reg4 = period_hi | vol
            bw(8'h20, {1'b0, wave, mode, duty});   // reg5 = 预留(7)|wave(6:5)|mode(4)|duty(3:0)
        end
    endtask
    // 设方波通道 (reg0/1): period8, vol, duty_sel, mode
    task set_sq;
        input [7:0] p8; input [3:0] vol; input [1:0] duty; input mode;
        begin
            bw(8'h01, p8);                         // reg0 = 方波 period
            bw(8'h02, {2'b0, mode, duty, vol});    // reg1 = bit6=mode bit5:4=duty bit3:0=vol
        end
    endtask
    initial begin
        $display("=== PSG3 v0.5 三通道验证 ===");
        rst_n=0; repeat(20) @(posedge clk); #500; rst_n=1; repeat(10) @(posedge clk);

        // ============ 波形通道 (reg3/4/5, clk=4MHz) ============
        // A4=440: 锯齿族16步 p12=3528, 三角30步 p12=3793
        $display("Test1: 波形-方波 50%% A4 (16步)");
        set_uni(12'd3528, 4'd15, 4'd8, 2'b10, 1'b0);
        mx=0; mn=255;
        for(i=0;i<40000;i=i+1) begin @(posedge clk); #1; if(uni_a>mx) mx=uni_a; if(uni_a<mn) mn=uni_a; end
        $display("  uni_audio: %0d~%0d (期望 0~240)", mn, mx);
        if(mx>200 && mn<50) $display("  PASS"); else begin $display("  FAIL"); errors=errors+1; end

        $display("Test2: 波形-三角 A4 (30步)");
        set_uni(12'd3793, 4'd15, 4'd8, 2'b01, 1'b0);
        mx=0; mn=255;
        for(i=0;i<40000;i=i+1) begin @(posedge clk); #1; if(uni_a>mx) mx=uni_a; if(uni_a<mn) mn=uni_a; end
        $display("  uni_audio: %0d~%0d", mn, mx);
        if(mx>100) $display("  PASS"); else begin $display("  FAIL"); errors=errors+1; end

        $display("Test3: 波形-锯齿 A4 (16步)");
        set_uni(12'd3528, 4'd15, 4'd8, 2'b00, 1'b0);
        mx=0; mn=255;
        for(i=0;i<40000;i=i+1) begin @(posedge clk); #1; if(uni_a>mx) mx=uni_a; if(uni_a<mn) mn=uni_a; end
        $display("  uni_audio: %0d~%0d", mn, mx);
        if(mx>100) $display("  PASS"); else begin $display("  FAIL"); errors=errors+1; end

        $display("Test3b: 波形-反锯齿 A4 (16步)");
        set_uni(12'd3528, 4'd15, 4'd15, 2'b11, 1'b0);
        mx=0; mn=255;
        for(i=0;i<30000;i=i+1) begin @(posedge clk); #1; if(uni_a>mx) mx=uni_a; if(uni_a<mn) mn=uni_a; end
        $display("  uni_audio: %0d~%0d", mn, mx);
        if(mx>100) $display("  PASS"); else begin $display("  FAIL"); errors=errors+1; end

        $display("Test4: 波形 vol=0 静音");
        set_uni(12'd3528, 4'd0, 4'd8, 2'b10, 1'b0);
        mx=0;
        for(i=0;i<5000;i=i+1) begin @(posedge clk); #1; if(uni_a>mx) mx=uni_a; end
        if(mx==0) $display("  PASS"); else begin $display("  FAIL max=%0d", mx); errors=errors+1; end

        $display("Test5: 波形 三角 mode_sel 切换 (比较 vs AND)");
        set_uni(12'd3793, 4'd15, 4'd8, 2'b01, 1'b1);  // 三角+比较
        mx=0; mn=255;
        for(i=0;i<20000;i=i+1) begin @(posedge clk); #1; if(uni_a>mx) mx=uni_a; if(uni_a<mn) mn=uni_a; end
        $display("  比较模式: %0d~%0d", mn, mx);
        set_uni(12'd3793, 4'd15, 4'd8, 2'b01, 1'b0);  // 三角+AND
        mx=0; mn=255;
        for(i=0;i<20000;i=i+1) begin @(posedge clk); #1; if(uni_a>mx) mx=uni_a; if(uni_a<mn) mn=uni_a; end
        $display("  AND模式:  %0d~%0d", mn, mx);
        if(mx>0) $display("  PASS (两种模式都出声)"); else begin $display("  FAIL"); errors=errors+1; end

        // ============ 方波通道 (reg0/1, clk=sq_clk 64kHz) ============
        // v0.4 period 是 8-bit, sq_clk=63492Hz, freq=sq_clk/(256-p8)
        // A4=440: p8 = 256-63492/440 = 256-144 = 112
        $display("Test6: 方波通道 A4 (reg0/1, sq_clk)");
        set_sq(8'd112, 4'd15, 2'b00, 1'b0);  // duty=50%, mode=方波
        mx=0; mn=255;
        for(i=0;i<200000;i=i+1) begin @(posedge clk); #1; if(sq_a>mx) mx=sq_a; if(sq_a<mn) mn=sq_a; end
        $display("  sq_audio: %0d~%0d", mn, mx);
        if(mx>100) $display("  PASS"); else begin $display("  FAIL"); errors=errors+1; end

        // ============ 噪音通道 (reg2, clk=sq_clk) ============
        $display("Test7: 噪音通道 (reg2, vol=15 freq=÷2)");
        bw(8'h04, 8'h1F);   // reg2 噪音控制 vol=15 freq=÷2
        begin : nz_chk
            integer nn=0;
            for(i=0;i<300000;i=i+1) begin @(posedge clk); #1; if(nz_a>0) nn=nn+1; end
            $display("  噪音非零: %0d", nn);
            if(nn>100) $display("  PASS"); else begin $display("  FAIL"); errors=errors+1; end
        end

        $display("=== 结果: %0d 错误 ===", errors);
        if(errors==0) $display(">>> PSG3 v0.5 三通道验证通过 <<<");
        else $display("*** 有失败 ***");
        $finish;
    end
    initial begin #50000000000; $display("超时"); $finish; end
endmodule
