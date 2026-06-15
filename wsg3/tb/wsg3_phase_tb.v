`timescale 1ns/1ps

module wsg3_phase_tb;
    reg SPFM_CLK;
    reg SPFM_RST_n;
    reg [7:0] SPFM_D;
    reg SPFM_A0;
    reg SPFM_CS_n;
    reg SPFM_WR_n;
    reg SPFM_RD_n;
    wire [7:0] dac_out;

    wsg3_core u_dut (
        .SPFM_CLK(SPFM_CLK),
        .SPFM_RST_n(SPFM_RST_n),
        .SPFM_D(SPFM_D),
        .SPFM_A0(SPFM_A0),
        .SPFM_CS_n(SPFM_CS_n),
        .SPFM_WR_n(SPFM_WR_n),
        .SPFM_RD_n(SPFM_RD_n),
        .dac_out(dac_out)
    );

    // SPFM 写任务
    task spfm_write;
        input [7:0] addr;
        input [7:0] data;
        begin
            @(posedge SPFM_CLK);
            SPFM_CS_n = 0;
            SPFM_WR_n = 0;
            SPFM_A0 = 0;
            SPFM_D = addr;
            @(posedge SPFM_CLK);
            SPFM_CS_n = 1;
            SPFM_WR_n = 1;
            repeat(8) @(posedge SPFM_CLK);
            SPFM_CS_n = 0;
            SPFM_WR_n = 0;
            SPFM_A0 = 1;
            SPFM_D = data;
            @(posedge SPFM_CLK);
            SPFM_CS_n = 1;
            SPFM_WR_n = 1;
            repeat(8) @(posedge SPFM_CLK);
        end
    endtask

    initial begin
        SPFM_CLK = 0;
        SPFM_RST_n = 0;
        SPFM_CS_n = 1;
        SPFM_WR_n = 1;
        SPFM_RD_n = 1;
        SPFM_A0 = 0;
        SPFM_D = 8'hzz;

        // Clock
        forever #5.208 SPFM_CLK = ~SPFM_CLK; // 6.144MHz

        // Reset
        #100;
        @(posedge SPFM_CLK);
        SPFM_RST_n = 1;
        repeat(10) @(posedge SPFM_CLK);

        // 写 A4=440Hz 频率: 0x012C6
        $display("Writing A4=440Hz frequency...");
        spfm_write(8'h50, 8'h06);  // acc[0] LSB
        spfm_write(8'h51, 8'h0C);  // acc[1]
        spfm_write(8'h52, 8'h02);  // acc[2]
        spfm_write(8'h53, 8'h01);  // acc[3]
        spfm_write(8'h54, 8'h00);  // acc[4] MSB
        spfm_write(8'h55, 8'h0F);  // vol=15
        spfm_write(8'h45, 8'h00);  // wave=0 (sine)

        $display("Monitoring phase and output...");
        // 监控 3 个完整 TDM 周期 (3 * 64 = 192 样本)
        repeat(200) @(posedge SPFM_CLK);
    end

    // 诊断: 监控关键信号
    wire [5:0] hcnt = u_dut.hcnt_r;
    wire [4:0] phase = u_dut.carry_chain[4:0];
    wire cp273 = u_dut.cp273;
    wire clk174 = u_dut.clk174;
    wire [7:0] rom_addr = {u_dut.acc_dout[2:0], u_dut.carry_chain[4:0]};

    always @(posedge SPFM_CLK) begin
        if (hcnt[5:2] == 4'd5 && hcnt[1:0] == 2'd0) begin
            $display("@%0t: hcnt=%02d step5_sub0 cp273=%b clk174=%b phase=%02d rom_addr=%02d",
                $time, hcnt, cp273, clk174, phase, rom_addr);
        end
        if (cp273) begin
            $display("@%0t: hcnt=%02d cp273 RISE phase=%02d rom_addr=%02d dac=%0d",
                $time, hcnt, phase, rom_addr, dac_out);
        end
    end

endmodule
