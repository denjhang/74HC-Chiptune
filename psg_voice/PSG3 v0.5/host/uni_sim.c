/* uni_sim.c — PSG3 v0.5 波形通道 C 仿真器
 *
 * 一个 CD4029 4-bit 计数器, wave_sel 切换波形:
 *   00 锯齿  01 三角  10 方波  11 反锯齿
 *
 * 周期分两类 (核心: 有无 CD4027 折返):
 *   锯齿族 (锯齿/方波/反锯齿): 单向回绕 = 16步/周期
 *       freq = 4MHz / (16 × (4096 - period12))
 *   三角 (折返 0→15→0): 30步/周期
 *       freq = 4MHz / (30 × (4096 - period12))
 *
 * 寄存器 (24bit = 3 reg):
 *   reg0: period12[7:0]
 *   reg1: period12[11:8] | vol[3:0]       (频率+音量在一起)
 *   reg2: duty[3:0] | wave_sel[1:0] | mode_sel | 预留
 *         wave_sel[1] = dir  (0=加=锯齿, 1=减=反锯齿)
 *         wave_sel[0] = fold (0=单向16步, 1=折返30步=三角)
 *         方波 = dir=0 + fold=0 + 强制走 HC85 比较 (mode_sel 无效)
 *         mode_sel: 1=HC85比较(阈值调制) 0=HC08 AND(位掩码)
 *
 * 编译: PATH="/d/msys64/mingw64/bin:$PATH" gcc -O2 -std=c99 uni_sim.c -o uni_sim.exe -lm
 * 运行: ./uni_sim          # 精度表 (双套: 16步族 + 30步三角)
 *       ./uni_sim table     # 双 period12 查找表
 *       ./uni_sim wav       # 88音4波形扫频 WAV
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define CLK_HZ      4000000.0
#define STEPS_SAW   16          /* 锯齿族: 单向回绕, 16步/周期 */
#define STEPS_TRI   30          /* 三角: 折返 0→15→0, 30步/周期 */
#define MIDI_LO     24          /* C1 (32.7Hz, 30步@4M 的下限) */
#define MIDI_HI     108         /* C8 */
#define N_NOTES     (MIDI_HI - MIDI_LO + 1)

/* ============ 波形类型 ============ */
enum { WAVE_SAW = 0, WAVE_TRI = 1, WAVE_SQUARE = 2, WAVE_RSAW = 3 };
static const char *WAVE_NAMES[] = {"锯齿", "三角", "方波", "反锯齿"};

/* ============ 硬件状态 ============ */
typedef struct {
    /* period 12-bit 上计数器 */
    unsigned cnt12;
    unsigned period12;
    /* CD4029 4-bit 可逆计数器 (16步波形) */
    int tri_q;          /* 0..15 */
    int tri_ud;         /* 1=加 0=减 */
    /* CD4027 方向 (三角折返) */
    int dir_q;
    /* 控制参数 */
    int wave_sel;       /* 0-3 */
    int duty;           /* 0-15, 比较阈值/AND掩码 */
    int mode_sel;       /* 1=比较(阈值调制) 0=AND(位掩码) */
    int vol;            /* 0-15 */
} hw_t;

/* freq_tc: period12 计数器每 (4096-period12) clk 产生一个脉冲 */
static int sim_step(hw_t *h) {
    int freq_tc = 0;
    h->cnt12++;
    if (h->cnt12 >= 4095) {
        h->cnt12 = h->period12;
        freq_tc = 1;
    }
    /* CD4029: freq_tc 时走一步. 周期按 wave_sel 分两类. */
    if (freq_tc) {
        int wave = h->wave_sel;
        if (wave == WAVE_TRI) {
            /* 三角: CD4027 折返, 0→15→0, 30步/周期 */
            int at_extreme = ((h->tri_ud && h->tri_q == 15) ||
                             (!h->tri_ud && h->tri_q == 0));
            if (at_extreme) h->dir_q ^= 1;
            h->tri_ud = 1 - h->dir_q;   /* 上电 dir=0 → ud=1=加 */
            if (h->tri_ud) h->tri_q = (h->tri_q >= 15) ? 0 : h->tri_q + 1;
            else           h->tri_q = (h->tri_q <= 0)  ? 15 : h->tri_q - 1;
        } else {
            /* 锯齿族: 单向回绕, 16步/周期. dir=0 加(锯齿/方波), dir=1 减(反锯齿) */
            int ud = (wave == WAVE_RSAW) ? 0 : 1;  /* 反锯齿=减, 其他=加 */
            if (ud) h->tri_q = (h->tri_q >= 15) ? 0 : h->tri_q + 1;
            else    h->tri_q = (h->tri_q <= 0)  ? 15 : h->tri_q - 1;
        }
    }
    return freq_tc;
}

/* 输出计算: mode_sel 选 比较输出(HC85) 或 AND输出(HC08) */
static unsigned wave_out(const hw_t *h) {
    unsigned q = h->tri_q;

    /* HC85 比较: q < duty → 全高 (阈值调制) */
    unsigned cmp = (q < (unsigned)h->duty) ? 15 : 0;
    /* HC08 AND: q & duty (位掩码调制) */
    unsigned and_out = q & (unsigned)h->duty;

    /* 方波: 固定比较输出 (占空比) */
    if (h->wave_sel == WAVE_SQUARE) return cmp;

    /* 三角/锯齿/反锯齿: mode_sel 选 比较输出 或 AND输出 */
    /* mode_sel=1: 比较 (三角→削顶方波, 加奇次谐波) */
    /* mode_sel=0: AND  (三角→位掩码, 加量化高频) */
    if (h->mode_sel) return cmp;
    return and_out;
}

/* TLC7524 级联: #1(波形 DB4-7) × #2(音量 DB4-7) / 256 */
static unsigned audio_out(const hw_t *h) {
    unsigned wave_db = wave_out(h) << 4;       /* Q0-3 → DB4-7 */
    unsigned vol_db  = (h->vol & 15) << 4;     /* vol0-15 → DB4-7 */
    return (wave_db * vol_db) >> 8;
}

/* ============ 音名/频率 ============ */
static double note_freq(int midi) { return 440.0 * pow(2.0, (midi-69)/12.0); }
static double f_actual(unsigned p12, int steps) { return CLK_HZ / (steps * (4096 - p12)); }
static const char *NAMES[] = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"};

/* 波形对应的步数: 三角=30, 锯齿族=16 */
static int steps_of(int wave) { return (wave == WAVE_TRI) ? STEPS_TRI : STEPS_SAW; }

/* 穷举优化 period12 */
static unsigned opt_period12(int midi, int steps) {
    double ft = note_freq(midi);
    double pt = 4096.0 - CLK_HZ / (steps * ft);
    int lo = (int)floor(pt)-3, hi = (int)ceil(pt)+3;
    if (lo < 1) lo = 1; if (hi > 4094) hi = 4094;
    unsigned bp = lo; double be = 999;
    for (int p = lo; p <= hi; p++) {
        double e = fabs(f_actual(p, steps) - ft) / ft * 100.0;
        if (e < be) { be = e; bp = p; }
    }
    return bp;
}

/* ============ WAV 写入 ============ */
static void wav_header(FILE *fp, int n, int rate) {
    int ds = n*2;
    fprintf(fp, "RIFF"); fwrite(&(int){36+ds},4,1,fp); fprintf(fp, "WAVE");
    fprintf(fp, "fmt "); fwrite(&(int){16},4,1,fp);
    fwrite(&(short){1},2,1,fp); fwrite(&(short){1},2,1,fp);
    fwrite(&rate,4,1,fp); fwrite(&(int){rate*2},4,1,fp);
    fwrite(&(short){2},2,1,fp); fwrite(&(short){16},2,1,fp);
    fprintf(fp, "data"); fwrite(&ds,4,1,fp);
}

/* ============ 主 ============ */
int main(int argc, char **argv) {
    int mode = 0;
    if (argc > 1) {
        if (!strcmp(argv[1], "table")) mode = 1;
        else if (!strcmp(argv[1], "wav")) mode = 2;
        else if (!strcmp(argv[1], "duty")) mode = 3;   /* 占空比/音色 demo */
        else if (!strcmp(argv[1], "vol"))  mode = 4;   /* 音量方案对比 */
    }

    /* 预计算 period12 双表: saw(16步) + tri(30步) */
    static unsigned ptable_saw[109], ptable_tri[109];
    static double err_saw[109], err_tri[109];
    for (int m = MIDI_LO; m <= MIDI_HI; m++) {
        ptable_saw[m] = opt_period12(m, STEPS_SAW);
        err_saw[m] = fabs(f_actual(ptable_saw[m], STEPS_SAW) - note_freq(m)) / note_freq(m) * 100.0;
        ptable_tri[m] = opt_period12(m, STEPS_TRI);
        err_tri[m] = fabs(f_actual(ptable_tri[m], STEPS_TRI) - note_freq(m)) / note_freq(m) * 100.0;
    }

    if (mode == 1) {
        /* 锯齿族表 (16步) */
        printf("/* PSG3 v0.5 period12 查找表 — 锯齿族 (16步@4MHz) */\n");
        printf("/* freq=4000000/(16×(4096-p12)), A4=440 十二平均律 */\n");
        printf("/* 覆盖: 锯齿/方波/反锯齿, 单向回绕16步/周期 */\n");
        printf("const unsigned uni_period12_saw[109] = {\n");
        printf("    /* MIDI 0-23 超范围 */\n    ");
        for (int m = 0; m < MIDI_LO; m++) { printf("0,"); if((m+1)%12==0) printf("\n    "); }
        printf("\n");
        for (int m = MIDI_LO; m <= MIDI_HI; m++)
            printf("    %4d,  /* MIDI %3d %s%d %.2fHz err=%.2f%% */\n",
                   ptable_saw[m], m, NAMES[m%12], m/12-1, note_freq(m), err_saw[m]);
        printf("};\n\n");

        /* 三角表 (30步) */
        printf("/* PSG3 v0.5 period12 查找表 — 三角 (30步@4MHz) */\n");
        printf("/* freq=4000000/(30×(4096-p12)), A4=440 十二平均律 */\n");
        printf("/* 覆盖: 三角, CD4027折返 0→15→0, 30步/周期 */\n");
        printf("const unsigned uni_period12_tri[109] = {\n");
        printf("    /* MIDI 0-23 超范围 */\n    ");
        for (int m = 0; m < MIDI_LO; m++) { printf("0,"); if((m+1)%12==0) printf("\n    "); }
        printf("\n");
        for (int m = MIDI_LO; m <= MIDI_HI; m++)
            printf("    %4d,  /* MIDI %3d %s%d %.2fHz err=%.2f%% */\n",
                   ptable_tri[m], m, NAMES[m%12], m/12-1, note_freq(m), err_tri[m]);
        printf("};\n");
        return 0;
    }

    if (mode == 2) {
        int rate = 250000;   /* 4MHz/16 = 每步16clk, 采样率取高些避免混叠 */
        double dur = 0.3;
        int spn = (int)(rate * dur);
        const char *fnames[4] = {
            "psg_voice/PSG3 v0.5/tb/saw_sweep.wav",
            "psg_voice/PSG3 v0.5/tb/tri_sweep.wav",
            "psg_voice/PSG3 v0.5/tb/sq_sweep.wav",
            "psg_voice/PSG3 v0.5/tb/rsaw_sweep.wav",
        };
        for (int w = 0; w < 4; w++) {
            FILE *fp = fopen(fnames[w], "wb");
            if (!fp) { perror(fnames[w]); return 1; }
            wav_header(fp, spn * N_NOTES, rate);
            /* 按波形选 period 表: 三角用30步表, 锯齿族用16步表 */
            unsigned *pt = (w == WAVE_TRI) ? ptable_tri : ptable_saw;
            int stp = steps_of(w);
            printf("生成 %s 扫频 (C1→C8, %d步)...\n", WAVE_NAMES[w], stp);
            for (int m = MIDI_LO; m <= MIDI_HI; m++) {
                hw_t h; memset(&h, 0, sizeof(h));
                h.period12 = pt[m]; h.wave_sel = w; h.duty = 8; h.vol = 15; h.tri_ud = 1;
                int warmup = stp * (4096 - pt[m]) * 3 + 200;
                for (int i = 0; i < warmup; i++) sim_step(&h);
                /* 采样: 每 16 clk 一个 (对齐 16步) */
                for (int s = 0; s < spn; s++) {
                    for (int k = 0; k < 16; k++) sim_step(&h);
                    unsigned a = audio_out(&h);
                    short v = (short)((a - 120) * 270);
                    fwrite(&v, 2, 1, fp);
                }
            }
            fclose(fp);
            printf("  → %s (%d音 %.1fs)\n", fnames[w], N_NOTES, N_NOTES*dur);
        }
        return 0;
    }

    if (mode == 3) {
        /* ---- 占空比扫描: 每波形一个WAV, C6音高, 16档duty连续扫 ---- */
        int rate = 250000;
        double dur = 0.5;           /* 每档 duty 0.5s */
        int spn = (int)(rate * dur);

        /* 3 个波形, 各扫 duty 0~15 */
        struct { const char *fname; int wave; } wavs[] = {
            {"psg_voice/PSG3 v0.5/tb/duty_saw.wav",  WAVE_SAW},
            {"psg_voice/PSG3 v0.5/tb/duty_tri.wav",  WAVE_TRI},
            {"psg_voice/PSG3 v0.5/tb/duty_sq.wav",   WAVE_SQUARE},
        };

        for (int w = 0; w < 3; w++) {
            int stp = steps_of(wavs[w].wave);
            unsigned p12 = opt_period12(84, stp);   /* C6=1046.5Hz, 按波形步数 */
            FILE *fp = fopen(wavs[w].fname, "wb");
            if (!fp) { perror(wavs[w].fname); return 1; }
            wav_header(fp, spn * 16, rate);   /* 16 档 */
            printf("生成 %s (C6, duty 0→15, %d步)...\n", wavs[w].fname, stp);

            for (int duty = 0; duty < 16; duty++) {
                hw_t h; memset(&h, 0, sizeof(h));
                h.period12 = p12; h.wave_sel = wavs[w].wave;
                h.duty = duty; h.vol = 15; h.tri_ud = 1;
                /* 方波内部已比较. 三角/锯齿开削顶看 duty 音色效果 */
                h.mode_sel = (wavs[w].wave != WAVE_SQUARE) ? 1 : 0;
                int warmup = stp * (4096 - p12) * 3 + 200;
                for (int i = 0; i < warmup; i++) sim_step(&h);
                for (int s = 0; s < spn; s++) {
                    for (int k = 0; k < 16; k++) sim_step(&h);
                    unsigned a = audio_out(&h);
                    short v = (short)((a - 120) * 270);
                    fwrite(&v, 2, 1, fp);
                }
            }
            fclose(fp);
            printf("  → %s (16档×%.1fs = %.0fs)\n", wavs[w].fname, dur, 16*dur);
        }
        return 0;
    }

    if (mode == 4) {
        /* ---- 音量衰减对比: AND门 vs TLC7524级联 ---- */
        /* C5=523Hz, 3 波形 × 2 方案 × 16 档音量 */
        int rate = 250000;
        double dur = 0.4;
        int spn = (int)(rate * dur);
        int waves[3] = {WAVE_SQUARE, WAVE_TRI, WAVE_SAW};
        const char *wnames[3] = {"sq", "tri", "saw"};

        for (int w = 0; w < 3; w++) {
            int stp = steps_of(waves[w]);
            unsigned p12 = opt_period12(72, stp);   /* C5, 按波形步数 */
            /* AND 门方案 */
            char fname[256];
            snprintf(fname, sizeof(fname), "psg_voice/PSG3 v0.5/tb/vol_and_%s.wav", wnames[w]);
            FILE *fp = fopen(fname, "wb");
            wav_header(fp, spn * 16, rate);
            printf("生成 AND门音量 %s (C5, vol 0→15, %d步)...\n", wnames[w], stp);
            for (int vol = 15; vol >= 0; vol--) {
                hw_t h; memset(&h, 0, sizeof(h));
                h.period12 = p12; h.wave_sel = waves[w]; h.duty = 8; h.vol = vol; h.tri_ud = 1;
                int warmup = stp * (4096 - p12) * 3 + 200;
                for (int i = 0; i < warmup; i++) sim_step(&h);
                for (int s = 0; s < spn; s++) {
                    for (int k = 0; k < 16; k++) sim_step(&h);
                    /* AND 门: wave_out AND vol → 单片 TLC7524 */
                    unsigned wave4 = wave_out(&h);
                    unsigned and_out = wave4 & (h.vol & 15);
                    unsigned db = and_out << 4;
                    short v = (short)((db - 120) * 270);
                    fwrite(&v, 2, 1, fp);
                }
            }
            fclose(fp);
            printf("  → %s\n", fname);

            /* TLC7524 级联方案 */
            snprintf(fname, sizeof(fname), "psg_voice/PSG3 v0.5/tb/vol_cascade_%s.wav", wnames[w]);
            fp = fopen(fname, "wb");
            wav_header(fp, spn * 16, rate);
            printf("生成 TLC7524级联音量 %s (C5, vol 15→0)...\n", wnames[w]);
            for (int vol = 15; vol >= 0; vol--) {
                hw_t h; memset(&h, 0, sizeof(h));
                h.period12 = p12; h.wave_sel = waves[w]; h.duty = 8; h.vol = vol; h.tri_ud = 1;
                int warmup = stp * (4096 - p12) * 3 + 200;
                for (int i = 0; i < warmup; i++) sim_step(&h);
                for (int s = 0; s < spn; s++) {
                    for (int k = 0; k < 16; k++) sim_step(&h);
                    /* 级联: #1(wave<<4) × #2(vol<<4) / 256 */
                    unsigned wave_db = wave_out(&h) << 4;
                    unsigned vol_db = (h.vol & 15) << 4;
                    unsigned db = (wave_db * vol_db) >> 8;
                    short v = (short)((db - 120) * 270);
                    fwrite(&v, 2, 1, fp);
                }
            }
            fclose(fp);
            printf("  → %s\n", fname);
        }
        return 0;
    }

    /* 默认: 精度表 (双套: 锯齿族16步 + 三角30步) */
    printf("=== PSG3 v0.5 波形通道精度 (clk=4MHz) ===\n\n");

    /* --- 锯齿族 (16步) --- */
    printf("--- 锯齿族 (单向16步): 锯齿/方波/反锯齿 ---\n");
    printf("公式: freq = %.0f / (%d × (4096 - period12))\n\n", CLK_HZ, STEPS_SAW);
    printf("MIDI 音名   目标Hz    p12     实测Hz    误差%%\n");
    printf("---- ---   -------   -----   -------   -----\n");
    {
    int u1 = 0; double worst = 0; int wm = 0;
    for (int m = MIDI_LO; m <= MIDI_HI; m++) {
        double ft = note_freq(m), fa = f_actual(ptable_saw[m], STEPS_SAW);
        if (err_saw[m] < 1.0) u1++;
        if (err_saw[m] > worst) { worst = err_saw[m]; wm = m; }
        printf("%3d  %s%-2d  %8.2f  %5d   %8.2f   %5.2f%s\n",
               m, NAMES[m%12], m/12-1, ft, ptable_saw[m], fa, err_saw[m],
               err_saw[m] < 1.0 ? "" : " !");
    }
    printf("\n锯齿族统计: <1%%: %d/%d, 最差 MIDI %d (%.2fHz) = %.2f%%\n\n",
           u1, N_NOTES, wm, note_freq(wm), worst);
    }

    /* --- 三角 (30步) --- */
    printf("--- 三角 (折返30步) ---\n");
    printf("公式: freq = %.0f / (%d × (4096 - period12))\n\n", CLK_HZ, STEPS_TRI);
    printf("MIDI 音名   目标Hz    p12     实测Hz    误差%%\n");
    printf("---- ---   -------   -----   -------   -----\n");
    {
    int u1 = 0; double worst = 0; int wm = 0;
    for (int m = MIDI_LO; m <= MIDI_HI; m++) {
        double ft = note_freq(m), fa = f_actual(ptable_tri[m], STEPS_TRI);
        if (err_tri[m] < 1.0) u1++;
        if (err_tri[m] > worst) { worst = err_tri[m]; wm = m; }
        printf("%3d  %s%-2d  %8.2f  %5d   %8.2f   %5.2f%s\n",
               m, NAMES[m%12], m/12-1, ft, ptable_tri[m], fa, err_tri[m],
               err_tri[m] < 1.0 ? "" : " !");
    }
    printf("\n三角统计: <1%%: %d/%d, 最差 MIDI %d (%.2fHz) = %.2f%%\n",
           u1, N_NOTES, wm, note_freq(wm), worst);
    }

    printf("\n寄存器: reg0=period[7:0], reg1=period[11:8]|vol[3:0], reg2=duty|wave[1:0]|mode|预留\n");
    printf("  wave_sel[1]=dir(0锯齿/1反锯齿), wave_sel[0]=fold(0单向16步/1折返30步)\n");
    printf("  方波 = dir=0+fold=0+强制比较\n");
    printf("\n./uni_sim table  → 双查找表\n");
    printf("./uni_sim wav    → 4波形扫频WAV\n");
    return 0;
}
