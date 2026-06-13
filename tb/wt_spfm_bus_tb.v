// wt_spfm_bus_tb.v — SPFM 总线接口测试台
`timescale 1ns/1ps

module wt_spfm_bus_tb;

reg         CLK, RST_n;
reg  [7:0]  D;
reg         A0, CS_n, WR_n, RD_n;
wire [7:0]  reg_addr, reg_data;
wire        addr_wr, data_wr;

wt_spfm_bus dut (
    .CLK(CLK), .RST_n(RST_n), .D(D),
    .A0(A0), .CS_n(CS_n), .WR_n(WR_n), .RD_n(RD_n),
    .reg_addr(reg_addr), .reg_data(reg_data),
    .addr_wr(addr_wr), .data_wr(data_wr)
);

// 10 MHz clock
always #50 CLK = ~CLK;

// YM2413 two-step write
// 地址写 → 等待 → 数据写 → 等待
task spfm_write;
    input [7:0] addr, data;
    begin
        // Address phase
        @(negedge CLK);
        D = addr; A0 = 0; CS_n = 0; WR_n = 0;
        repeat (5) @(posedge CLK);
        CS_n = 1; WR_n = 1;
        repeat (10) @(posedge CLK);  // gap (≥4 clocks for sync clear)

        // Data phase
        @(negedge CLK);
        D = data; A0 = 1; CS_n = 0; WR_n = 0;
        repeat (5) @(posedge CLK);
        CS_n = 1; WR_n = 1;
        repeat (10) @(posedge CLK);
    end
endtask

reg [7:0] captured_addr, captured_data;
integer write_count;
always @(posedge CLK) begin
    if (addr_wr) begin
        captured_addr <= reg_data;
        $display("  [%0t] addr_wr: reg_data=%02X", $time, reg_data);
    end
    if (data_wr) begin
        captured_data <= reg_data;
        write_count <= write_count + 1;
        $display("  [%0t] data_wr: reg_data=%02X reg_addr=%02X", $time, reg_data, reg_addr);
    end
end

integer err_cnt, i;

initial begin
    CLK = 0; RST_n = 0;
    D = 8'h00; A0 = 0; CS_n = 1; WR_n = 1; RD_n = 1;
    captured_addr = 8'h00; captured_data = 8'h00;
    write_count = 0;

    #300; RST_n = 1;
    #200;

    $display("=== SPFM Bus Interface Test ===");

    // Test 1-4: Basic register writes
    $display("\n--- Test 1: CTRL (0x00, 0x02) ---");
    spfm_write(8'h00, 8'h02);
    #500;
    if (captured_addr === 8'h00 && captured_data === 8'h02)
        $display("PASS");
    else
        $display("FAIL: addr=%02X data=%02X", captured_addr, captured_data);

    $display("\n--- Test 2: step_lo (0x04, 0x67) ---");
    spfm_write(8'h04, 8'h67);
    #500;
    if (captured_addr === 8'h04 && captured_data === 8'h67)
        $display("PASS");
    else
        $display("FAIL: addr=%02X data=%02X", captured_addr, captured_data);

    $display("\n--- Test 3: step_hi (0x05, 0x00) ---");
    spfm_write(8'h05, 8'h00);
    #500;
    if (captured_addr === 8'h05 && captured_data === 8'h00)
        $display("PASS");
    else
        $display("FAIL: addr=%02X data=%02X", captured_addr, captured_data);

    $display("\n--- Test 4: note_on (0x06, 0x01) ---");
    spfm_write(8'h06, 8'h01);
    #500;
    if (captured_addr === 8'h06 && captured_data === 8'h01)
        $display("PASS");
    else
        $display("FAIL: addr=%02X data=%02X", captured_addr, captured_data);

    // Test 5: 10 rapid writes
    $display("\n--- Test 5: 10 sequential writes ---");
    err_cnt = 0;
    for (i = 0; i < 10; i = i + 1) begin
        spfm_write(i[7:0], {4'hA, i[3:0]});
        #100;
        if (captured_addr !== i[7:0] || captured_data !== {4'hA, i[3:0]}) begin
            $display("FAIL at i=%0d: addr=%02X data=%02X", i, captured_addr, captured_data);
            err_cnt = err_cnt + 1;
        end
    end
    if (err_cnt == 0) $display("PASS");
    else $display("FAIL: %0d errors", err_cnt);

    // Test 6: Reset
    $display("\n--- Test 6: Reset ---");
    spfm_write(8'hFF, 8'hFF);
    RST_n = 0; #300;
    if (reg_addr === 8'h00) $display("PASS");
    else $display("FAIL: reg_addr=%02X", reg_addr);
    RST_n = 1; #200;

    $display("\n=== Done. Writes: %0d ===", write_count);
    $finish;
end

initial begin
    $dumpfile("wt_spfm_bus_tb.vcd");
    $dumpvars(0, wt_spfm_bus_tb);
end

endmodule
