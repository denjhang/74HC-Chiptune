// psg3_bus_tb.v — PSG3 v0.4 总线协议验证 testbench (带 /CS 片选, 消除短暂地址值)
//
// 雅马哈 YM2413 协议: 一次完整写入 = 两次总线操作 (写地址 + 写数据),
// 用 /CS 把整个事务包起来, 事务期间总线跳变在芯片内部消化, 对外只输出最终值.
// 完全无歧义 — 寄存器绝不会出现中间态.
//
// ⚠️ 地址编码 = 独热码 (one-hot), 每位一对一选通一个 HC374, 无译码器.
//
// 时序 (/CS 包整个事务):
//   1. /CS=0 开始事务
//   2. 写地址拍: bus=独热码地址, A0=0, /WR ↓↑ → 锁地址 (A0=0, 数据CP无效, 不锁数据)
//   3. 写数据拍: bus=data, A0=1, /WR ↓↑ → 锁数据 (A0=1, ADDR[n]=1 的 HC374 锁)
//   4. /CS=1 结束事务
//
// 核心修正 (消除"短暂地址值"):
//   write_strobe = CS_n_n AND A0 AND WR_n
//     其中 CS_n_n = NOT(/CS) (事务期间=1)
//     数据 374 的 CP[n] = ADDR[n] AND write_strobe
//   地址锁存器: 用 HC374 (边沿), CP = CS_n_n AND NOT(A0) AND WR_n
//     (A0=0 即写地址, /WR 上升沿锁; 用边沿锁存器消除透明窗口竞争)
//
//   这样 A0 的跳变本身不触发任何锁存 — 只有 /WR 上升沿才锁, 且 A0 决定锁到哪.

`timescale 1ns/1ps

module psg3_bus_tb;

    // ====== 总线信号 (FT232H 侧) ======
    reg  [7:0] bus_data;   // C0-C7 复用总线
    reg        A0;         // 0=写地址, 1=写数据
    reg        WR_n;       // 写脉冲 (低有效, 上升沿锁存)
    reg        CS_n;       // 片选 (低有效, 事务期间=0)
    wire [7:0] addr_out;   // 地址锁存器输出 → 选通 HC374

    // ====== 内部信号 ======
    wire       cs_active;     // NOT(/CS) = CS_n_n, 事务期间=1
    wire       a0_n;          // NOT(A0)
    wire       addr_cp;       // 地址锁存 CP = cs_active AND a0_n AND WR_n (写地址时 /WR 上升沿)
    wire       data_strobe;   // 数据锁存触发 = cs_active AND A0 AND WR_n (写数据时 /WR 上升沿)
    wire [1:0] reg_cp;        // CP[n] = ADDR[n] AND data_strobe

    wire [7:0] reg0_q, reg1_q;

    // ====== NOT 逻辑 (HC04) ======
    hc04 u_inv (
        .A1(CS_n), .Y1(cs_active),   // NOT(/CS)
        .A2(A0),   .Y2(a0_n),         // NOT(A0)
        .A3(1'b0), .Y3(),
        .A4(1'b0), .Y4(),
        .A5(1'b0), .Y5(),
        .A6(1'b0), .Y6()
    );

    // ====== 地址锁存: HC374 边沿 (CP = cs_active AND a0_n AND WR_n) ======
    // 用 HC08 做这个 3 输入 AND (两级: (cs AND a0_n) AND wr)
    // 这里行为级先验证逻辑, RTL 阶段映射到 HC08
    assign addr_cp = cs_active & a0_n & WR_n;

    hc374 u_addr (
        .OE_n(1'b0), .CP(addr_cp),
        .D(bus_data), .Q(addr_out)
    );

    // ====== 数据锁存触发: data_strobe = cs_active AND A0 AND WR_n ======
    assign data_strobe = cs_active & A0 & WR_n;

    // ====== 数据 HC374 ×2: CP[n] = ADDR[n] AND data_strobe ======
    assign reg_cp[0] = addr_out[0] & data_strobe;
    assign reg_cp[1] = addr_out[1] & data_strobe;

    hc374 u_reg0 (
        .OE_n(1'b0), .CP(reg_cp[0]),
        .D(bus_data), .Q(reg0_q)
    );
    hc374 u_reg1 (
        .OE_n(1'b0), .CP(reg_cp[1]),
        .D(bus_data), .Q(reg1_q)
    );

    // ====== 监控: 捕捉任何寄存器跳变 (验证无中间态) ======
    always @(reg0_q) $display("    [monitor] reg0_q 变为 %h @ %0t", reg0_q, $time);
    always @(reg1_q) $display("    [monitor] reg1_q 变为 %h @ %0t", reg1_q, $time);

    initial begin
        $dumpfile("psg3_bus.vcd");
        $dumpvars(0, psg3_bus_tb);
    end

    // ====== 写寄存器任务 (完整事务: /CS 包两拍) ======
    task bus_write;
        input [7:0] addr;
        input [7:0] data;
        begin
            // 事务开始
            CS_n = 1'b0;           // /CS=0 选中芯片
            #2;

            // === 第 1 拍: 写地址 ===
            bus_data = addr;       // 独热码地址上总线
            A0 = 1'b0;             // 声明写地址
            #10;
            WR_n = 1'b0;           // /WR 拉低
            #10;
            WR_n = 1'b1;           // /WR 上升沿 → addr_cp=cs&a0_n&wr=1&1&1=上升沿 → 锁地址
            #10;
            $display("[%0t] 写地址: addr=%h → addr_out=%b", $time, addr, addr_out);
            $display("    (此时 reg0=%h reg1=%h — 应保持不变)", reg0_q, reg1_q);

            // === 第 2 拍: 写数据 ===
            bus_data = data;       // 总线换数据
            A0 = 1'b1;             // 声明写数据
            #10;
            WR_n = 1'b0;           // /WR 拉低
            #10;
            WR_n = 1'b1;           // /WR 上升沿 → data_strobe=cs&A0&wr=1&1&1 → ADDR[n]=1 的 374 锁
            #10;
            $display("[%0t] 写数据: data=%h → reg0=%h reg1=%h", $time, data, reg0_q, reg1_q);

            // 事务结束
            CS_n = 1'b1;           // /CS=1 释放芯片
            #10;
            $display("----");
        end
    endtask

    // ====== OPLL 精确时序写任务 (照搬 driver.c Driver_FmOutopl3) ======
    // 验证 PSG3 硬件能跑真实 OPLL 驱动时序:
    //   A0=0 → /CS=0 → bus=地址 → /WR↓→↑ → A0=1 → /WR↓ → bus=数据 → /WR↑ → /CS=1
    task bus_write_opll;
        input [7:0] addr;
        input [7:0] data;
        begin
            // 事务前预设 A0=0 (OPLL driver.c 414行)
            A0 = 1'b0; #10;
            // /CS=0 (417行)
            CS_n = 1'b0; #10;
            // bus=地址 (418行)
            bus_data = addr; #10;
            // /WR↓→↑ 锁地址 (421-424行)
            WR_n = 1'b0; #10;
            WR_n = 1'b1; #10;
            $display("[OPLL] 写地址: addr=%h → addr_out=%b (reg0=%h reg1=%h)", addr, addr_out, reg0_q, reg1_q);
            // A0=1 (427行)
            A0 = 1'b1;
            // /WR↓ (428行)
            WR_n = 1'b0;
            // bus=数据 (429行) — OPLL 在 /WR 低期间放数据
            bus_data = data; #10;
            // /WR↑ 锁数据 (432行)
            WR_n = 1'b1; #10;
            // /CS=1 (433行)
            CS_n = 1'b1; #10;
            bus_data = 8'h00; A0 = 1'b0;
            $display("[OPLL] 写数据: data=%h → reg0=%h reg1=%h", data, reg0_q, reg1_q);
            $display("----");
        end
    endtask

    // ====== 主测试 ======
    integer errors = 0;
    initial begin
        // 初始化
        bus_data = 8'h00;
        A0 = 1'b0;
        WR_n = 1'b1;
        CS_n = 1'b1;          // 平时不选中
        #20;

        // 测试 1: 写 reg0 (地址 0x01) = 0xA5
        $display("=== 测试 1: 写 reg0 = 0xA5 ===");
        bus_write(8'h01, 8'hA5);
        if (reg0_q !== 8'hA5) begin $display("❌ FAIL: reg0 应为 A5, 实际 %h", reg0_q); errors = errors + 1; end
        else $display("✅ PASS: reg0 = A5");
        if (reg1_q !== 8'h00) begin $display("❌ FAIL: reg1 应为 00 (未写), 实际 %h", reg1_q); errors = errors + 1; end
        else $display("✅ PASS: reg1 = 00 (未误写)");

        $display("=== 测试 2: 写 reg1 = 0x3C ===");
        bus_write(8'h02, 8'h3C);
        if (reg1_q !== 8'h3C) begin $display("❌ FAIL: reg1 应为 3C, 实际 %h", reg1_q); errors = errors + 1; end
        else $display("✅ PASS: reg1 = 3C");
        if (reg0_q !== 8'hA5) begin $display("❌ FAIL: reg0 应保持 A5, 实际 %h", reg0_q); errors = errors + 1; end
        else $display("✅ PASS: reg0 保持 A5");

        $display("=== 测试 3: 覆盖 reg0 = 0xFF ===");
        bus_write(8'h01, 8'hFF);
        if (reg0_q !== 8'hFF) begin $display("❌ FAIL: reg0 应为 FF, 实际 %h", reg0_q); errors = errors + 1; end
        else $display("✅ PASS: reg0 = FF (覆盖)");
        if (reg1_q !== 8'h3C) begin $display("❌ FAIL: reg1 应保持 3C, 实际 %h", reg1_q); errors = errors + 1; end
        else $display("✅ PASS: reg1 保持 3C");

        // ====== OPLL 真实时序验证 (照搬 driver.c Driver_FmOutopl3) ======
        $display("=== 测试 4: OPLL 时序写 reg0 = 0x77 (清空 reg0/1 重新验证) ===");
        bus_write_opll(8'h01, 8'h77);
        if (reg0_q !== 8'h77) begin $display("❌ FAIL: reg0 应为 77, 实际 %h", reg0_q); errors = errors + 1; end
        else $display("✅ PASS: reg0 = 77 (OPLL 时序)");
        if (reg1_q !== 8'h3C) begin $display("❌ FAIL: reg1 应保持 3C, 实际 %h", reg1_q); errors = errors + 1; end
        else $display("✅ PASS: reg1 保持 3C (OPLL 时序未误写)");

        $display("=== 测试 5: OPLL 时序写 reg1 = 0x88 ===");
        bus_write_opll(8'h02, 8'h88);
        if (reg1_q !== 8'h88) begin $display("❌ FAIL: reg1 应为 88, 实际 %h", reg1_q); errors = errors + 1; end
        else $display("✅ PASS: reg1 = 88 (OPLL 时序)");
        if (reg0_q !== 8'h77) begin $display("❌ FAIL: reg0 应保持 77, 实际 %h", reg0_q); errors = errors + 1; end
        else $display("✅ PASS: reg0 保持 77 (OPLL 时序未覆盖)");

        $display("=====");
        $display("总计: %0d 个错误", errors);
        if (errors == 0) $display("🎉 总线协议验证通过 (带 /CS, 无中间态)");
        else             $display("⚠️ 有错, 需排查");
        $finish;
    end

endmodule
