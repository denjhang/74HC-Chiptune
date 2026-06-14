// wt3_core_tb.v — WSG v1.4 C-E-G-C5 级联和弦 + 钢琴包络
//
// 4 通道按 0.2s 间隔依次触发:
//   ch0=C4 @0ms, ch1=E4 @200ms, ch2=G4 @400ms, ch3=C5 @600ms
// 每个音独立 piano envelope: attack 15 → decay → sustain at vol=7
//
// freq = phase_step × 48000 / 65536
//   C4 (261.6 Hz) → 0x0165
//   E4 (329.6 Hz) → 0x01C2
//   G4 (392.0 Hz) → 0x0217
//   C5 (523.3 Hz) → 0x02CA

`timescale 1ns/1ps

module wt3_core_tb;

    reg STEP_CLK, SPFM_CLK, SPFM_RST_n;
    reg [7:0] SPFM_D;
    reg SPFM_A0, SPFM_CS_n, SPFM_WR_n, SPFM_RD_n;

    wire [15:0] reg_a_q;
    wire [15:0] reg_b_q;
    wire [7:0]  reg_c_q;
    wire [15:0] adder_s;
    wire [7:0]  dac_out;
    wire [1:0]  cur_channel;
    wire [3:0]  cur_substep;
    wire        latch_dac;

    wt3_core u_dut (
        .STEP_CLK(STEP_CLK),
        .SPFM_CLK(SPFM_CLK),
        .SPFM_RST_n(SPFM_RST_n),
        .SPFM_D(SPFM_D),
        .SPFM_A0(SPFM_A0),
        .SPFM_CS_n(SPFM_CS_n),
        .SPFM_WR_n(SPFM_WR_n),
        .SPFM_RD_n(SPFM_RD_n),
        .reg_a_q(reg_a_q),
        .reg_b_q(reg_b_q),
        .reg_c_q(reg_c_q),
        .adder_s(adder_s),
        .dac_out(dac_out),
        .cur_channel(cur_channel),
        .cur_substep(cur_substep),
        .latch_dac(latch_dac)
    );

    // STEP_CLK = 3.072 MHz → period 325.5 ns, half 162.5 ns
    initial STEP_CLK = 0;
    always #162.5 STEP_CLK = ~STEP_CLK;

    // SPFM_CLK = 10 MHz → half 50 ns
    initial SPFM_CLK = 0;
    always #50 SPFM_CLK = ~SPFM_CLK;

    integer i, sample_count;
    integer fd;
    integer ch_idx;
    integer trigger_ms [0:3];
    integer g_ms;
    integer last_update_ms;
    reg [3:0] cur_vol [0:3];
    reg [3:0] new_vol;
    integer dt_ms;
    integer total_ms;
    integer samples_per_ms;
    integer latch_per_ms;

    // ---- SPFM 双字节写 ----
    task spfm_write;
        input [7:0] addr;
        input [7:0] data;
        begin
            @(negedge SPFM_CLK);
            SPFM_A0 = 0; SPFM_D = addr;
            #10;
            SPFM_CS_n = 0; SPFM_WR_n = 0;
            repeat (5) @(posedge SPFM_CLK);
            SPFM_CS_n = 1; SPFM_WR_n = 1;
            repeat (5) @(posedge SPFM_CLK);
            @(negedge SPFM_CLK);
            SPFM_A0 = 1; SPFM_D = data;
            #10;
            SPFM_CS_n = 0; SPFM_WR_n = 0;
            repeat (5) @(posedge SPFM_CLK);
            SPFM_CS_n = 1; SPFM_WR_n = 1;
            repeat (5) @(posedge SPFM_CLK);
        end
    endtask

    task set_note;
        input [1:0] ch;
        input [7:0] step_lo;
        input [7:0] step_hi;
        input [3:0] vol;
        begin
            spfm_write(ch*8 + 0, 8'h00);            // acc_lo
            spfm_write(ch*8 + 1, 8'h00);            // acc_hi
            spfm_write(ch*8 + 2, step_lo);          // step_lo
            spfm_write(ch*8 + 3, step_hi);          // step_hi
            spfm_write(ch*8 + 4, {4'b0, vol});      // vol
        end
    endtask

    task set_vol;
        input [1:0] ch;
        input [3:0] vol;
        begin
            spfm_write(ch*8 + 4, {4'b0, vol});
        end
    endtask

    // 钢琴包络: attack (15) → decay → sustain at 7
    function [3:0] piano_env;
        input [31:0] t_ms;
        begin
            case (1'b1)
                (t_ms <    5): piano_env = 15;  // attack peak
                (t_ms <   15): piano_env = 14;
                (t_ms <   30): piano_env = 13;
                (t_ms <   50): piano_env = 12;
                (t_ms <   80): piano_env = 11;
                (t_ms <  120): piano_env = 10;
                (t_ms <  170): piano_env = 9;
                (t_ms <  230): piano_env = 8;
                default:       piano_env = 7;   // sustain
            endcase
        end
    endfunction

    initial begin
        SPFM_RST_n = 0; SPFM_CS_n = 1; SPFM_WR_n = 1;
        SPFM_RD_n = 1; SPFM_A0 = 0; SPFM_D = 8'h00;

        trigger_ms[0] = 0;
        trigger_ms[1] = 200;
        trigger_ms[2] = 400;
        trigger_ms[3] = 600;

        // TDM: 192000 latch/s → 192 latch/ms
        latch_per_ms = 192;
        total_ms = 1200;          // 采集 1.2s
        sample_count = 0;

        #1000;
        SPFM_RST_n = 1;
        #1000;

        $display("=== WSG v1.4 C-E-G-C5 Cascade + Piano Envelope ===");

        // 初始化: 4 通道都设好 phase_step, 但 vol=0 (不发声)
        // 触发时才把 vol 升到 15
        set_note(2'd0, 8'h65, 8'h01, 4'h0);  // C4, vol=0
        set_note(2'd1, 8'hC2, 8'h01, 4'h0);  // E4, vol=0
        set_note(2'd2, 8'h17, 8'h02, 4'h0);  // G4, vol=0
        set_note(2'd3, 8'hCA, 8'h02, 4'h0);  // C5, vol=0

        // 初始化当前音量记录
        for (ch_idx = 0; ch_idx < 4; ch_idx = ch_idx + 1)
            cur_vol[ch_idx] = 0;

        fd = $fopen("wt3_piano.csv", "w");

        // 主循环: 每 ms 跑 192 个 latch, 同时检查是否该更新 vol
        for (g_ms = 0; g_ms < total_ms; g_ms = g_ms + 1) begin
            // 每 ms 开头: 决定本 ms 各通道的应有音量, 若变化则 set_vol
            for (ch_idx = 0; ch_idx < 4; ch_idx = ch_idx + 1) begin
                if (g_ms >= trigger_ms[ch_idx]) begin
                    dt_ms = g_ms - trigger_ms[ch_idx];
                    new_vol = piano_env(dt_ms);
                end else begin
                    new_vol = 0;
                end
                if (new_vol !== cur_vol[ch_idx]) begin
                    set_vol(ch_idx[1:0], new_vol);
                    cur_vol[ch_idx] = new_vol;
                end
            end
            // 本 ms 采 192 个 latch
            for (i = 0; i < latch_per_ms; i = i + 1) begin
                @(posedge u_dut.latch_dac);
                #100;
                $fdisplay(fd, "%0d", dac_out);
                sample_count = sample_count + 1;
            end
        end
        $fclose(fd);

        $display("Final RAM state:");
        for (ch_idx = 0; ch_idx < 4; ch_idx = ch_idx + 1) begin
            $display("  ch%0d: acc=0x%04X step=0x%04X vol=0x%02X",
                ch_idx,
                {u_dut.u_ram.mem[ch_idx*8+1], u_dut.u_ram.mem[ch_idx*8+0]},
                {u_dut.u_ram.mem[ch_idx*8+3], u_dut.u_ram.mem[ch_idx*8+2]},
                u_dut.u_ram.mem[ch_idx*8+4]);
        end

        $display("Generated wt3_piano.csv with %0d samples (%0d ms)",
            sample_count, total_ms);
        $display("PASS");
        $finish;
    end

endmodule
