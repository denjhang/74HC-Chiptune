`timescale 1ns/1ps
// wt_ram_tb.v — 62256 RAM 架构 WT 合成器 testbench
// 行为级 62256 RAM + 39SF040 ROM 模型
// SPFM 总线驱动, 输出 WAV 采样
module wt_ram_tb;

reg         clk;
reg   [7:0] d_out;
wire  [7:0] d;
reg         cs_n;
reg         a0;
reg         wr_n;
reg         rd_n;
reg         rst_n;

wire [18:0] rom_addr;
wire  [7:0] rom_data;
wire [14:0] ram_addr;
wire  [7:0] ram_io;
wire        ram_we_n;
wire        ram_oe_n;
wire        ram_cs_n;
wire  [7:0] dac_out;

assign d = (~wr_n) ? d_out : 8'bz;

// ---- 39SF040 ROM 模型 ----
reg [7:0] rom [0:524287];
initial begin
    $readmemh("rom/wt_39sf040.hex", rom);
end
assign rom_data = rom[rom_addr];

// ---- 62256 RAM 模型 ----
reg [7:0] sram [0:32767];
integer i;
initial begin
    for (i = 0; i < 32768; i = i + 1)
        sram[i] = 0;
end

// RAM 三态驱动
reg ram_drive_model;
reg [7:0] ram_out_data;
assign ram_io = ram_drive_model ? ram_out_data : 8'bz;

// RAM 读: 异步组合逻辑 (62256 SRAM 是异步读)
always @(*) begin
    if (!ram_oe_n && !ram_cs_n) begin
        ram_out_data = sram[ram_addr];
        ram_drive_model = 1;
    end else begin
        ram_out_data = 8'bz;
        ram_drive_model = 0;
    end
end

// RAM 写: negedge clk 采样 (DUT 的非阻塞赋值已传播)
always @(negedge clk) begin
    if (!ram_we_n && !ram_cs_n)
        sram[ram_addr] = ram_io;
end

// DUT
wt_ram dut (
    .clk(clk),
    .d(d),
    .cs_n(cs_n),
    .a0(a0),
    .wr_n(wr_n),
    .rd_n(rd_n),
    .rst_n(rst_n),
    .rom_addr(rom_addr),
    .rom_data(rom_data),
    .ram_addr(ram_addr),
    .ram_io(ram_io),
    .ram_we_n(ram_we_n),
    .ram_oe_n(ram_oe_n),
    .ram_cs_n(ram_cs_n),
    .dac_out(dac_out)
);

initial clk = 0;
always #50 clk = ~clk;

// SPFM 写 task
task spfm_write;
    input [7:0] addr;
    input [7:0] data;
    begin
        @(posedge clk); #10;
        a0 = 0; d_out = addr;
        @(posedge clk); #10;
        cs_n = 0; wr_n = 0;
        repeat (4) @(posedge clk);
        wr_n = 1; cs_n = 1;
        @(posedge clk);

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

integer fd, n;

initial begin
    fd = $fopen("wt_ram_output.csv", "w");
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

    // 等一个采样周期, 让 SPFM note_on 写完 RAM
    repeat (312) @(posedge clk);

    // ---- ch1: sine E4 ----
    spfm_write(8'h00, 8'h01);
    spfm_write(8'h01, 8'h03);      // sine
    spfm_write(8'h02, 8'h1F);
    spfm_write(8'h03, 8'd64);
    spfm_write(8'h04, 8'd84);      // E4
    spfm_write(8'h05, 8'd0);
    spfm_write(8'h06, 8'd0);

    repeat (312) @(posedge clk);

    // ---- ch2: sine G4 ----
    spfm_write(8'h00, 8'h02);
    spfm_write(8'h01, 8'h03);      // sine
    spfm_write(8'h02, 8'h1F);
    spfm_write(8'h03, 8'd64);
    spfm_write(8'h04, 8'd100);     // G4
    spfm_write(8'h05, 8'd0);
    spfm_write(8'h06, 8'd0);

    repeat (312) @(posedge clk);

    // 采样 16000 次 (C major chord)
    for (n = 0; n < 16000; n = n + 1) begin
        repeat (312) @(posedge clk);
        $fdisplay(fd, "%0d,%0d", n, $signed(dac_out));
    end

    // release all
    spfm_write(8'h00, 8'h00); spfm_write(8'h07, 8'd0);
    repeat (100) @(posedge clk);
    spfm_write(8'h00, 8'h01); spfm_write(8'h07, 8'd0);
    repeat (100) @(posedge clk);
    spfm_write(8'h00, 8'h02); spfm_write(8'h07, 8'd0);
    repeat (100) @(posedge clk);

    for (n = 0; n < 4000; n = n + 1) begin
        repeat (312) @(posedge clk);
        $fdisplay(fd, "%0d,%0d", n + 16000, $signed(dac_out));
    end

    // ---- 多音色测试 ----
    // ch0: sqr C4
    spfm_write(8'h00, 8'h00);
    spfm_write(8'h01, 8'h00); spfm_write(8'h02, 8'h1F);
    spfm_write(8'h03, 8'd64); spfm_write(8'h04, 8'd67); spfm_write(8'h05, 8'd0);
    spfm_write(8'h06, 8'd0);
    repeat (312) @(posedge clk);

    // ch1: saw E4
    spfm_write(8'h00, 8'h01);
    spfm_write(8'h01, 8'h04); spfm_write(8'h02, 8'h1F);
    spfm_write(8'h03, 8'd64); spfm_write(8'h04, 8'd84); spfm_write(8'h05, 8'd0);
    spfm_write(8'h06, 8'd0);
    repeat (312) @(posedge clk);

    // ch2: noise G4
    spfm_write(8'h00, 8'h02);
    spfm_write(8'h01, 8'h05); spfm_write(8'h02, 8'h1F);
    spfm_write(8'h03, 8'd64); spfm_write(8'h04, 8'd100); spfm_write(8'h05, 8'd0);
    spfm_write(8'h06, 8'd0);
    repeat (312) @(posedge clk);

    // ch3: sine C5
    spfm_write(8'h00, 8'h03);
    spfm_write(8'h01, 8'h03); spfm_write(8'h02, 8'h1F);
    spfm_write(8'h03, 8'd64); spfm_write(8'h04, 8'd134); spfm_write(8'h05, 8'd0);
    spfm_write(8'h06, 8'd0);
    repeat (312) @(posedge clk);

    for (n = 0; n < 16000; n = n + 1) begin
        repeat (312) @(posedge clk);
        $fdisplay(fd, "%0d,%0d", n + 20000, $signed(dac_out));
    end

    $fclose(fd);
    $display("Done. 36000 samples.");
    $finish;
end

endmodule
