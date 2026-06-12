`timescale 1ns/1ps
// wt_spfm_tb.v — SPFM 总线接口 4通道 WT 合成器 testbench
// YM2413 风格总线时序: A0 先行, CS_n 建立后放数据, WR_n 脉冲
module wt_spfm_tb;

reg         clk;
reg   [7:0] d_out;
wire  [7:0] d;
reg         cs_n;
reg         a0;
reg         wr_n;
reg         rd_n;
reg         rst_n;
wire  [7:0] dac_out;

assign d = (~wr_n) ? d_out : 8'bz;

wt_top dut (
    .clk(clk),
    .d(d),
    .cs_n(cs_n),
    .a0(a0),
    .wr_n(wr_n),
    .rd_n(rd_n),
    .rst_n(rst_n),
    .dac_out(dac_out)
);

initial clk = 0;
always #50 clk = ~clk;

// SPFM 写 (YM2413 风格):
// 地址写: A0=0, CS_n=0, WR_n=0, D=addr (保持 ≥3 个时钟)
// 数据写: A0=1, CS_n=0, WR_n=0, D=data (保持 ≥3 个时钟)
// 同步链需要 2-3 个时钟周期处理, 所以写脉冲宽度要够
task spfm_write;
    input [7:0] addr;
    input [7:0] data;
    begin
        // 地址阶段: A0=0
        @(posedge clk); #10;
        a0 = 0; d_out = addr;
        @(posedge clk); #10;
        cs_n = 0; wr_n = 0;
        repeat (4) @(posedge clk); // 保持 4 个周期, 确保同步链捕获
        wr_n = 1; cs_n = 1;
        @(posedge clk);

        // 数据阶段: A0=1
        #10;
        a0 = 1; d_out = data;
        @(posedge clk); #10;
        cs_n = 0; wr_n = 0;
        repeat (4) @(posedge clk);
        wr_n = 1; cs_n = 1;
        @(posedge clk);
        d_out = 8'bz;
    end
endtask

integer fd, i;

initial begin
    fd = $fopen("wt_output.csv", "w");
    $fdisplay(fd, "sample,dac_signed");

    cs_n = 1; wr_n = 1; rd_n = 1; a0 = 0; d_out = 8'bz;
    rst_n = 0;
    #500;
    rst_n = 1;
    #500;

    // ---- ch0: sine C4 ----
    spfm_write(8'h00, 8'h00);      // CTRL: select ch0
    spfm_write(8'h01, 8'h03);      // wave_idx = sine
    spfm_write(8'h02, 8'h1F);      // vol = 31
    spfm_write(8'h03, 8'd64);      // env_rate = 64
    spfm_write(8'h04, 8'd67);      // step_lo = 67 (C4)
    spfm_write(8'h05, 8'd0);       // step_hi = 0
    spfm_write(8'h06, 8'd0);       // note_on

    // ---- ch1: sine E4 ----
    spfm_write(8'h00, 8'h01);      // select ch1
    spfm_write(8'h01, 8'h03);      // sine
    spfm_write(8'h02, 8'h1F);      // vol = 31
    spfm_write(8'h03, 8'd64);
    spfm_write(8'h04, 8'd84);      // step_lo = 84 (E4)
    spfm_write(8'h05, 8'd0);
    spfm_write(8'h06, 8'd0);       // note_on

    // ---- ch2: sine G4 ----
    spfm_write(8'h00, 8'h02);      // select ch2
    spfm_write(8'h01, 8'h03);      // sine
    spfm_write(8'h02, 8'h1F);
    spfm_write(8'h03, 8'd64);
    spfm_write(8'h04, 8'd100);     // step_lo = 100 (G4)
    spfm_write(8'h05, 8'd0);
    spfm_write(8'h06, 8'd0);       // note_on

    // 采样 16000 次 (C major chord)
    for (i = 0; i < 16000; i = i + 1) begin
        repeat (312) @(posedge clk);
        $fdisplay(fd, "%0d,%0d", i, $signed(dac_out));
    end

    // release all
    spfm_write(8'h00, 8'h00); spfm_write(8'h07, 8'd0);
    spfm_write(8'h00, 8'h01); spfm_write(8'h07, 8'd0);
    spfm_write(8'h00, 8'h02); spfm_write(8'h07, 8'd0);

    for (i = 0; i < 4000; i = i + 1) begin
        repeat (312) @(posedge clk);
        $fdisplay(fd, "%0d,%0d", i + 16000, $signed(dac_out));
    end

    // ---- 多音色测试 ----
    // ch0: sqr C4
    spfm_write(8'h00, 8'h00);
    spfm_write(8'h01, 8'h00); spfm_write(8'h02, 8'h1F);
    spfm_write(8'h03, 8'd64); spfm_write(8'h04, 8'd67); spfm_write(8'h05, 8'd0);
    spfm_write(8'h06, 8'd0);

    // ch1: saw E4
    spfm_write(8'h00, 8'h01);
    spfm_write(8'h01, 8'h04); spfm_write(8'h02, 8'h1F);
    spfm_write(8'h03, 8'd64); spfm_write(8'h04, 8'd84); spfm_write(8'h05, 8'd0);
    spfm_write(8'h06, 8'd0);

    // ch2: noise G4
    spfm_write(8'h00, 8'h02);
    spfm_write(8'h01, 8'h05); spfm_write(8'h02, 8'h1F);
    spfm_write(8'h03, 8'd64); spfm_write(8'h04, 8'd100); spfm_write(8'h05, 8'd0);
    spfm_write(8'h06, 8'd0);

    // ch3: sine C5
    spfm_write(8'h00, 8'h03);
    spfm_write(8'h01, 8'h03); spfm_write(8'h02, 8'h1F);
    spfm_write(8'h03, 8'd64); spfm_write(8'h04, 8'd134); spfm_write(8'h05, 8'd0);
    spfm_write(8'h06, 8'd0);

    for (i = 0; i < 16000; i = i + 1) begin
        repeat (312) @(posedge clk);
        $fdisplay(fd, "%0d,%0d", i + 20000, $signed(dac_out));
    end

    $fclose(fd);
    $display("Done. 36000 samples.");
    $finish;
end

endmodule
