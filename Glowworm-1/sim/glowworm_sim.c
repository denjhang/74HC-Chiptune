//==============================================================================
// glowworm_sim.c —— 萤火虫1号 CPU 指令级仿真器
//------------------------------------------------------------------------------
// 目的：
//   1. 严格按 ISA 实现，能加载 glowcc 编译的 rom.bin 端到端跑
//   2. 暴露每条指令的语义细节（dst=9 / 0x10xx / 0x29xx 等待查清）
//   3. 后续加指令/时钟统计，为 SCC 特化提供依据
//
// 编译：gcc -O2 -Wall -o glowworm_sim glowworm_sim.c
// 用法：./glowworm_sim rom.bin [max_cycles] [-v] [-trace start end]
//==============================================================================
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

//---------- 配置 ----------
#define ROM_SIZE   (1 << 20)   // 1 MB
#define RF_SIZE    256         // RF 寄存器堆（RA 寻址）
#define DATA_SIZE  (1 << 16)   // 数据 RAM 64K

//---------- 状态 ----------
static uint8_t  rom[ROM_SIZE];      // 程序/ALU 表 ROM（字节流）
static uint8_t  rf[RF_SIZE];        // RF 寄存器堆
static uint8_t  data_ram[DATA_SIZE];

static uint32_t pc;            // 程序计数器（字节地址，+2 步进）
static uint8_t  A, B, RA;
static uint8_t  A0, A1, A2;
static uint8_t  IO0, IO1;
static int      IO0_oe, IO1_oe;
static uint16_t alu_out;       // ALU 输出锁存（16 位，含标志位）

// 统计
static uint64_t cycle_count = 0;
static uint64_t insn_count  = 0;
static uint64_t stat_by_op[256];   // 每种 opcode 执行次数

//---------- 调试 ----------
static int      verbose = 0;
static uint64_t trace_start = 0, trace_end = 0;
static int      trace_on = 0;
static int      mark_mode = 0;       // -mark：每次 IO0 变化打印 cycle（性能基准用）
static uint64_t mark_first = 0;     // 第一次 IO0 变化的 cycle
static uint64_t mark_last  = 0;     // 上次 IO0 变化的 cycle
static uint64_t mark_count = 0;     // IO0 变化次数
static uint8_t  last_IO0 = 0xFF;

// 取 16 位指令（大端：高字节=opcode 在前）
static inline uint16_t fetch(uint32_t addr) {
    if (addr + 1 >= ROM_SIZE) return 0xFFFF;
    return ((uint16_t)rom[addr] << 8) | rom[addr + 1];
}

// ALU 表实现：地址 = {A, B}（XX 段先按函数实现，跑通后改成真实查表）
// 返回 16 位：低 8 位结果，bit0 用于 JCC
// 模式号来自 GlowCompilerDlg.cpp 的 alu_str[25]
static uint16_t alu_compute(uint8_t a, uint8_t b, uint8_t mode) {
    uint16_t r16 = 0;
    uint8_t  r8  = 0;
    int      bit0 = 0;   // JCC 判据：bit0=0 跳
    int      carry = 0;  // ADD_C / SUB_C 输入
    int      sum, diff;

    switch (mode) {
        case 0:  // ADD：A+B
            sum = a + b; r8 = sum & 0xFF; bit0 = (r8 == 0);  // 待查：bit0 含义
            carry = (sum >> 8) & 1;
            r16 = (carry << 8) | r8;  // 高 8 位放进位（待校准）
            break;
        case 1:  // SUB：A-B
            diff = a - b; r8 = diff & 0xFF; bit0 = (a >= b);
            carry = (diff < 0) ? 1 : 0;
            r16 = (carry << 8) | r8;
            break;
        case 2:  // ADD_C：A+B+进位（进位来自上次 ADD 的 bit8）
            // 这里进位输入语义待查；先用 alu_out 的 bit8
            sum = a + b + ((alu_out >> 8) & 1);
            r8 = sum & 0xFF; carry = (sum >> 8) & 1;
            r16 = (carry << 8) | r8;
            break;
        case 3:  // SUB_C：A-B-借位
            diff = a - b - ((alu_out >> 8) & 1);
            r8 = diff & 0xFF; carry = (diff < 0) ? 1 : 0;
            r16 = (carry << 8) | r8;
            break;
        case 4:  // EQUAL_C：A==B? bit0=1 (相等)
            r8 = 0;
            bit0 = (a == b) ? 0 : 1;  // JCC 用：bit0==0 跳；这里 a==b 时 bit0=0 → 不跳
            // 等等，JCC 语义是"ALU.bit0==0 跳"。EQUAL_C 应该 a==b 时 bit0=0（不跳），a!=b 时 bit0=1（跳）
            // 反了？看 glow.cpp IFALU_PC_ASGN_IMMNUM(ALU_EQUAL_C, label_0) 用法：
            //   是"如果 ALU 结果为某状态则跳到 label_0"。待 trace 校准。
            r16 = r8 | (bit0 & 1);
            break;
        case 5:  // AND
            r8 = a & b; r16 = r8; break;
        case 6:  // OR
            r8 = a | b; r16 = r8; break;
        case 7:  // A_NOT
            r8 = ~a; r16 = r8; break;
        case 8:  // XOR
            r8 = a ^ b; r16 = r8; break;
        case 9:  // A_BH_LSH：A 带高半左移（保留高 4 位）—— 具体语义待查
            r8 = (a & 0xF0) | ((a << 1) & 0x0F); r16 = r8; break;
        case 10: // B_AL_RSH：B 算术右移（保留低半）
            r8 = (b >> 1) | (b & 0x80); r16 = r8; break;
        case 11: // A_AH_RSH：A 算术右移（保留高半）
            r8 = (a >> 1) | (a & 0xF0); r16 = r8; break;
        case 12: // A_0_RSH：A 逻辑右移补 0
            r8 = a >> 1; r16 = r8; break;
        case 13: // A_0_LSH：A 逻辑左移补 0
            r8 = a << 1; r16 = r8; break;
        case 14: // B_0_LSH：B 逻辑左移补 0
            r8 = b << 1; r16 = r8; break;
        case 15: // MUL_L：A*B 低字节
            r8 = (a * b) & 0xFF; r16 = r8; break;
        case 16: // MUL_H：A*B 高字节
            r8 = (a * b) >> 8; r16 = r8; break;
        case 17: // DIV：A/B
            r8 = b ? (a / b) : 0xFF; r16 = r8; break;
        case 18: // MOD：A%B
            r8 = b ? (a % b) : a; r16 = r8; break;
        case 19: // A_ADD_1：A+1
            sum = a + 1; r8 = sum & 0xFF; bit0 = (r8 == 0);
            carry = (sum >> 8) & 1;
            r16 = (carry << 8) | r8;
            break;
        case 20: // A_SUB_1：A-1
            diff = a - 1; r8 = diff & 0xFF; bit0 = (a == 0);
            carry = (diff < 0) ? 1 : 0;
            r16 = (carry << 8) | r8;
            break;
        case 21: // A_ADD_1_C：A+1+进位
            sum = a + 1 + ((alu_out >> 8) & 1);
            r8 = sum & 0xFF; carry = (sum >> 8) & 1;
            r16 = (carry << 8) | r8;
            break;
        case 22: // A_SUB_1_C：A-1-借位
            diff = a - 1 - ((alu_out >> 8) & 1);
            r8 = diff & 0xFF; carry = (diff < 0) ? 1 : 0;
            r16 = (carry << 8) | r8;
            break;
        case 23: // OUTA：输出 A
            r8 = a; r16 = r8; break;
        case 24: // OUTB：输出 B
            r8 = b; r16 = r8; break;
        default:
            r8 = a; r16 = r8; break;
    }
    // bit0：JCC 判据。把它放到 r16 的 bit0（独立于结果字节）
    // 注意：r16 低 8 位是结果，bit8 是进位，bit0 这里被 result 覆盖了
    // 修正：JCC 单独读 bit0，所以我们要让 bit0 反映判据
    // 上面 case 里设置了 bit0，这里 OR 进 r16 的 bit0
    // 但 r8 已占 bit0-7... 真实硬件 ALU 输出 16 位，低 8 是结果，高 8 是标志
    // JCC 判 bit0 应该是低 8 位的 bit0（结果本身的 bit0）还是高 8 位的某个标志？
    // 看 glow.cpp 17XX 注释："如果ALU输出最低位为0" → 低 8 位结果的 bit0
    // 所以 JCC 判的是 r8 的 bit0，不是单独的 flag
    // 对 EQUAL_C：bit0 应该编码比较结果。我们让 r8.bit0 = (a != b)
    if (mode == 4) {
        r8 = (a != b) ? 1 : 0;  // 不等=1，等=0；JCC bit0==0 跳 → 不等时不跳？矛盾
        // 实际：IFALU_PC_ASGN_IMMNUM(ALU_EQUAL_C, label_0) 的 label_0 在 glow_cpu_init 里
        // 是"B==0 时跳"。所以 EQUAL_C 应该：a==b 时 bit0=0（跳），a!=b 时 bit0=1（不跳）
        // 即 r8.bit0 = (a != b) ? 1 : 0 → 错，应该 a==b 时 bit0=0
        // wait: a==b → bit0=0 → JCC 跳；所以 EQUAL_C 的语义是"相等时跳"，与 IFALU_PC_ASGN_IMMNUM(ALU_EQUAL_C, label) 的"等于时跳到 label"一致
        r8 = (a != b) ? 1 : 0;
        r16 = r8;
    }
    return r16;
}

//---------- 主执行循环 ----------
int main(int argc, char** argv) {
    const char* rom_file = NULL;
    uint64_t max_cycles = 100000;
    int argi = 1;
    while (argi < argc) {
        if (strcmp(argv[argi], "-v") == 0) { verbose = 1; argi++; }
        else if (strcmp(argv[argi], "-mark") == 0) { mark_mode = 1; argi++; }
        else if (strcmp(argv[argi], "-trace") == 0 && argi + 2 < argc) {
            trace_start = strtoull(argv[argi+1], NULL, 0);
            trace_end   = strtoull(argv[argi+2], NULL, 0);
            trace_on = 1; argi += 3;
        } else if (!rom_file) { rom_file = argv[argi++]; }
        else { max_cycles = strtoull(argv[argi++], NULL, 0); }
    }
    if (!rom_file) {
        fprintf(stderr, "usage: %s rom.bin [max_cycles] [-v] [-trace start end]\n", argv[0]);
        return 1;
    }

    FILE* fp = fopen(rom_file, "rb");
    if (!fp) { perror("open rom"); return 1; }
    size_t n = fread(rom, 1, ROM_SIZE, fp);
    fclose(fp);
    fprintf(stderr, "loaded %zu bytes from %s\n", n, rom_file);

    // 初始化
    pc = 0; A = B = RA = 0; A0 = A1 = A2 = 0;
    IO0 = 0xFF; IO1 = 0xFF; IO0_oe = IO1_oe = 0;
    alu_out = 0;
    memset(rf, 0, sizeof(rf));
    memset(data_ram, 0, sizeof(data_ram));

    // 执行
    while (cycle_count < max_cycles) {
        uint16_t ir = fetch(pc);
        uint8_t  op = ir >> 8;
        uint8_t  xx = ir & 0xFF;
        uint8_t  src_hi = op >> 4;
        uint8_t  dst_lo = op & 0x0F;

        // trace
        if (trace_on && cycle_count >= trace_start && cycle_count < trace_end) {
            fprintf(stderr, "cyc=%llu pc=%06x ir=%04x  A=%02x B=%02x RA=%02x A0=%02x A1=%02x A2=%02x IO0=%02x/%d alu=%04x\n",
                (unsigned long long)cycle_count, pc, ir, A, B, RA, A0, A1, A2, IO0, IO0_oe, alu_out);
        }

        // 选源数据
        uint8_t src = 0;
        int src_valid = 1;
        switch (src_hi) {
            case 0x0: src = xx; break;
            case 0x1: src = alu_compute(A, B, xx) & 0xFF; break;  // ALU[xx]，触发计算
            case 0x2: src = rf[RA]; break;
            case 0x3: src = data_ram[((uint32_t)A2 << 16 | A1 << 8 | A0) & (DATA_SIZE-1)]; break;
            case 0x4: src = IO0; break;   // 输入由外设驱动；这里简化为读回锁存值
            case 0x5: src = IO1; break;
            default:  src_valid = 0; break;
        }

        // 锁存 ALU 输出（任何 ALU 相关操作都更新 alu_out）
        if (src_hi == 0x1) {
            alu_out = alu_compute(A, B, xx);
        }

        // 跳转 / NOP / 普通
        // 注意：A2A1A0 是字地址（编译器约定 rom_cp>>1），硬件 PC 是字节地址，
        // 跳转目标字节地址 = A2A1A0 * 2
        uint32_t a2a1a0 = ((uint32_t)A2 << 16) | (A1 << 8) | A0;
        uint32_t jump_target = a2a1a0 * 2;
        uint32_t next_pc = pc + 2;
        if (op == 0x07) {
            next_pc = jump_target;
        } else if (op == 0x17) {
            // JCC: ALU[xx].bit0==0 跳
            uint16_t a = alu_compute(A, B, xx);
            alu_out = a;
            if ((a & 1) == 0) next_pc = jump_target;
        } else if (op == 0xFF) {
            // NOP
        } else if (src_valid) {
            switch (dst_lo) {
                case 0x0: rf[RA] = src; break;                              // RF
                case 0x1: A = src; break;
                case 0x2: A0 = src; break;
                case 0x3: A1 = src; break;
                case 0x4: A2 = src; break;
                case 0x5: RA = src; break;
                case 0x6: B = src; break;
                case 0x8: data_ram[((uint32_t)A2 << 16 | A1 << 8 | A0) & (DATA_SIZE-1)] = src; break;
                case 0x9:
                    // dst=9 (ALU[xx]=源)：触发 ALU 计算 (A,B,xx)，结果写 RF[RA]
                    // src 不参与计算（src=RF[RA] 是"被写入"方，不是输入）
                    // 编译器用法：ALU_ASGN__RF(op, ra) = RA=ra; ALU[op]=RF
                    //   即先设 RA，再用 (A,B,op) 计算，结果写 RF[RA]
                    alu_out = alu_compute(A, B, xx);
                    rf[RA] = alu_out & 0xFF;
                    break;
                case 0xA: IO0 = src; IO0_oe = 1; break;
                case 0xB: IO1 = src; IO1_oe = 1; break;
                default: break;
            }
        }

        stat_by_op[op]++;
        pc = next_pc;
        cycle_count++;
        insn_count++;

        // mark 模式：每次 IO0 变化都记录（用于性能基准——程序每完成一次"采样"就 IO0 = ~IO0）
        if (mark_mode && IO0_oe && IO0 != last_IO0) {
            if (mark_count == 0) mark_first = cycle_count;
            if (mark_count >= 1) {
                // 打印这次和上次之间的周期数（除第一次启动开销）
                if (mark_count <= 5 || mark_count % 100 == 0) {
                    fprintf(stderr, "  mark #%llu: cyc=%llu  delta=%llu\n",
                        (unsigned long long)mark_count,
                        (unsigned long long)cycle_count,
                        (unsigned long long)(cycle_count - mark_last));
                }
            }
            mark_last = cycle_count;
            mark_count++;
            last_IO0 = IO0;
        }

        // 非 mark 模式：检测 IO0 = 0x55（test2 验证）
        if (!mark_mode && IO0_oe && IO0 == 0x55) {
            fprintf(stderr, "[PASS] IO0 = 0x55 at cycle %llu (pc=%06x)\n",
                (unsigned long long)cycle_count, pc);
            goto done;
        }
    }
    if (mark_mode) {
        // 性能报告
        if (mark_count > 1) {
            uint64_t total = mark_last - mark_first;
            uint64_t per_mark = total / (mark_count - 1);
            fprintf(stderr, "[MARK] %llu marks, total %llu cyc, per-mark %llu cyc\n",
                (unsigned long long)mark_count,
                (unsigned long long)total,
                (unsigned long long)per_mark);
            fprintf(stderr, "       @8MHz: %.1f marks/s   @50MHz: %.1f marks/s\n",
                8.0e6 / per_mark, 50.0e6 / per_mark);
        }
    } else {
        fprintf(stderr, "[TIMEOUT] pc=%06x IO0=%02x/%d after %llu cycles\n",
            pc, IO0, IO0_oe, (unsigned long long)cycle_count);
    }

done:
    fprintf(stderr, "insn=%llu  cycles=%llu\n",
        (unsigned long long)insn_count, (unsigned long long)cycle_count);
    if (verbose) {
        fprintf(stderr, "--- opcode histogram ---\n");
        for (int i = 0; i < 256; i++)
            if (stat_by_op[i])
                fprintf(stderr, "  op %02x: %llu\n", i, (unsigned long long)stat_by_op[i]);
    }
    return 0;
}
