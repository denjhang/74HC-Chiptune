`timescale 1ns/1ps
// wt_rtl_tb.v — 74HC 门级实例 testbench (快速版, 少样本)
module wt_rtl_tb;

reg clk; reg [7:0] d_out; wire [7:0] d;
reg cs_n, a0, wr_n, rd_n, rst_n;
wire [18:0] rom_addr; wire [7:0] rom_data;
wire [14:0] ram_addr; wire [7:0] ram_io;
wire ram_we_n, ram_oe_n, ram_cs_n;
wire [7:0] dac_out;

assign d = (~wr_n) ? d_out : 8'bz;

reg [7:0] rom [0:524287];
initial $readmemh("rom/wt_39sf040.hex", rom);
assign rom_data = rom[rom_addr];

reg [7:0] sram [0:32767];
integer i;
initial for (i=0; i<32768; i=i+1) sram[i]=0;
reg ram_dm; reg [7:0] ram_od;
assign ram_io = ram_dm ? ram_od : 8'bz;
always @(*) begin
    if (!ram_oe_n && !ram_cs_n) begin ram_od = sram[ram_addr]; ram_dm = 1; end
    else begin ram_od = 8'bz; ram_dm = 0; end
end
always @(negedge clk) begin
    if (!ram_we_n && !ram_cs_n) sram[ram_addr] = ram_io;
end

wt_rtl dut (
    .clk(clk), .d(d), .cs_n(cs_n), .a0(a0),
    .wr_n(wr_n), .rd_n(rd_n), .rst_n(rst_n),
    .rom_addr(rom_addr), .rom_data(rom_data),
    .ram_addr(ram_addr), .ram_io(ram_io),
    .ram_we_n(ram_we_n), .ram_oe_n(ram_oe_n), .ram_cs_n(ram_cs_n),
    .dac_out(dac_out)
);

initial clk = 0;
always #50 clk = ~clk;

task spfm_write;
    input [7:0] addr, data;
    begin
        @(posedge clk); #10;
        a0=0; d_out=addr;
        @(posedge clk); #10;
        cs_n=0; wr_n=0;
        repeat (4) @(posedge clk);
        wr_n=1; cs_n=1;
        @(posedge clk);
        #10; a0=1; d_out=data;
        @(posedge clk); #10;
        cs_n=0; wr_n=0;
        repeat (4) @(posedge clk);
        wr_n=1; cs_n=1;
        @(posedge clk);
        d_out=8'bz;
    end
endtask

integer fd, n;

initial begin
    fd = $fopen("wt_rtl_output.csv", "w");
    $fdisplay(fd, "sample,dac_signed");

    cs_n=1; wr_n=1; rd_n=1; a0=0; d_out=8'bz;
    rst_n=0; #500; rst_n=1; #500;

    // ch0: sine C4
    spfm_write(8'h00, 8'h00);
    spfm_write(8'h01, 8'h03); spfm_write(8'h02, 8'h1F);
    spfm_write(8'h03, 8'd64); spfm_write(8'h04, 8'd67); spfm_write(8'h05, 8'd0);
    spfm_write(8'h06, 8'd0);
    repeat (312) @(posedge clk);

    // ch1: sine E4
    spfm_write(8'h00, 8'h01);
    spfm_write(8'h01, 8'h03); spfm_write(8'h02, 8'h1F);
    spfm_write(8'h03, 8'd64); spfm_write(8'h04, 8'd84); spfm_write(8'h05, 8'd0);
    spfm_write(8'h06, 8'd0);
    repeat (312) @(posedge clk);

    // ch2: sine G4
    spfm_write(8'h00, 8'h02);
    spfm_write(8'h01, 8'h03); spfm_write(8'h02, 8'h1F);
    spfm_write(8'h03, 8'd64); spfm_write(8'h04, 8'd100); spfm_write(8'h05, 8'd0);
    spfm_write(8'h06, 8'd0);
    repeat (312) @(posedge clk);

    // 5000 samples (enough for DFT, envelope reaches max)
    for (n=0; n<5000; n=n+1) begin
        repeat (312) @(posedge clk);
        $fdisplay(fd, "%0d,%0d", n, $signed(dac_out));
    end

    $fclose(fd);
    $display("Done. 5000 samples.");
    $finish;
end

endmodule
