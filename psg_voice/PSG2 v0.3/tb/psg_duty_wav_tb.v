// psg_duty_wav_tb.v — 生成方波占空比 4 挡 WAV 试听
// A4=440Hz (period=183), 4 挡各 0.5 秒

`timescale 1ns/1ps

module psg_duty_wav_tb;

    reg clk = 0;
    localparam CLK_HZ = 64000;
    localparam CLK_PERIOD = 1_000_000_000 / CLK_HZ;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg        rst_n = 0;
    reg        period_le = 0;
    reg        A0 = 0;
    reg  [7:0] data = 0;
    wire [7:0] audio_out;
    wire       tc_out;

    psg_square_duty_v03 u_dut (
        .clk(clk), .rst_n(rst_n),
        .period_le(period_le), .A0(A0),
        .data(data),
        .audio_out(audio_out),
        .tc_out(tc_out)
    );

    task write_period;
        input [7:0] p;
        begin data=p; #200; period_le=1; #500; period_le=0; #200; end
    endtask
    task write_ctrl;
        input [7:0] c;
        begin data=c; #200; A0=1; #500; A0=0; #200; end
    endtask

    integer fp, idx, ret;
    task wopen; input [8*40-1:0] fn; begin
        fp=$fopen(fn,"wb");
        $fwrite(fp,"RIFF%c%c%c%c",0,0,0,0); $fwrite(fp,"WAVEfmt %c%c%c%c",16,0,0,0);
        $fwrite(fp,"%c%c%c%c",1,0,1,0); $fwrite(fp,"%c%c%c%c",8'h00,8'hFA,0,0);
        $fwrite(fp,"%c%c%c%c",8'h00,8'hF4,1,0); $fwrite(fp,"%c%c%c%c",2,0,16,0);
        $fwrite(fp,"data%c%c%c%c",0,0,0,0); idx=0;
    end endtask
    task wsmp; input [7:0] a; integer s; begin
        s=(a==0)?-16000:16000; $fwrite(fp,"%c%c",s[7:0],s[15:8]); idx=idx+1; end endtask
    task wclose; integer fs,ds; begin
        ds=idx*2; fs=36+ds; ret=$fseek(fp,4,0);
        $fwrite(fp,"%c%c%c%c",fs[7:0],fs[15:8],fs[23:16],fs[31:24]);
        ret=$fseek(fp,40,0);
        $fwrite(fp,"%c%c%c%c",ds[7:0],ds[15:8],ds[23:16],ds[31:24]); $fclose(fp); end endtask

    localparam SMP = 32000;   // 0.5s
    integer i;

    task gen_duty;
        input [1:0] duty;
        input [8*40-1:0] fn;
        begin
            wopen(fn);
            write_ctrl(8'h0F | (duty << 4));   // vol=15 在 bit0-3, duty 在 bit4-5
            for (i=0; i<SMP; i=i+1) begin
                @(posedge clk); #1; wsmp(audio_out);
            end
            wclose;
            $display("  OK duty=%b (%0s)", duty, fn);
        end
    endtask

    initial begin
        rst_n=0; repeat(10)@(posedge clk); rst_n=1; repeat(30)@(posedge clk);
        write_period(8'd183);   // A4=440Hz
        $display("=== 方波占空比 4 挡 WAV (A4=440Hz) ===");
        gen_duty(2'b00, "duty_50_A4.wav");
        gen_duty(2'b01, "duty_25_A3.wav");
        gen_duty(2'b10, "duty_125_A2.wav");
        gen_duty(2'b11, "duty_25_A2.wav");
        $display("=== 完成 ==="); $finish;
    end

    initial begin #5_000_000_000; $display("超时"); $finish; end

endmodule
