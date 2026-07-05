// SCC 单通道最小算法开销测试
// 每次循环：phase += step; sample = wave[phase >> 16]; out = (sample * vol) >> 8; IO0 = out;
extern unsigned char REGISTER_IO0;
#define IO0 REGISTER_IO0

unsigned char wave[16] = {0,1,2,3,4,5,6,7,8,7,6,5,4,3,2,1};  // 三角波 16 点

void main() {
    unsigned long phase = 0;
    unsigned long step  = 0x00100000;   // 每次相位累加值
    unsigned char vol   = 64;
    unsigned char sample, out;
    int i;

    for (i = 0; i < 100; i++) {
        phase += step;
        sample = wave[(phase >> 28) & 15];   // 用高 4 位索引 16 点波形
        out = (sample * vol) >> 8;
        IO0 = out;
    }
    while (1);
}
