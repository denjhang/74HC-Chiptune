`timescale 1ns/1ps

module wt_top_tb;

reg         clk;
reg   [7:0] addr;
reg   [7:0] data_in;
wire  [7:0] data;
reg         cs_n;
reg         wr_n;
reg         rd_n;
reg         rst_n;
wire  [7:0] dac_out;

assign data = (~wr_n) ? data_in : 8'bz;

wt_top dut (
    .clk(clk),
    .addr(addr),
    .data(data),
    .cs_n(cs_n),
    .wr_n(wr_n),
    .rd_n(rd_n),
    .rst_n(rst_n),
    .dac_out(dac_out)
);

initial clk = 0;
always #50 clk = ~clk;

task bus_write;
    input [7:0] a;
    input [7:0] d;
    begin
        @(posedge clk);
        addr = a; data_in = d; cs_n = 0; wr_n = 0;
        @(posedge clk);
        wr_n = 1; cs_n = 1;
    end
endtask

integer fd, i;

initial begin
    fd = $fopen("wt_output.csv", "w");
    $fdisplay(fd, "sample,dac_signed");

    addr = 0; data_in = 0; cs_n = 1; wr_n = 1; rd_n = 1;
    rst_n = 0;
    #500;
    rst_n = 1;
    #200;

    // ch0: C4 (261Hz), atk_rate=64
    bus_write(8'h01, 8'h86);
    bus_write(8'h02, 8'h00);
    bus_write(8'h03, 8'h40);  // atk_rate = 64

    // ch1: E4 (330Hz), atk_rate=64
    bus_write(8'h04, 8'hA9);
    bus_write(8'h05, 8'h00);
    bus_write(8'h06, 8'h40);

    // ch0 note_on + start
    bus_write(8'h00, 8'h03);

    // 采样 64000 次 ≈ 2秒
    for (i = 0; i < 64000; i = i + 1) begin
        repeat (312) @(posedge clk);
        $fdisplay(fd, "%0d,%0d", i, $signed(dac_out));
    end

    // ch0 note_off
    bus_write(8'h00, 8'h05);

    // 再采 32000 ≈ 1秒 (release)
    for (i = 0; i < 32000; i = i + 1) begin
        repeat (312) @(posedge clk);
        $fdisplay(fd, "%0d,%0d", i + 64000, $signed(dac_out));
    end

    // 改频率到 A4 (440Hz) step=0x00E1
    bus_write(8'h01, 8'hE1);
    bus_write(8'h02, 8'h00);
    // ch0 note_on again
    bus_write(8'h00, 8'h03);

    for (i = 0; i < 32000; i = i + 1) begin
        repeat (312) @(posedge clk);
        $fdisplay(fd, "%0d,%0d", i + 96000, $signed(dac_out));
    end

    $fclose(fd);
    $display("Done. 128000 samples in wt_output.csv");
    $finish;
end

endmodule
