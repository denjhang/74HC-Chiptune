// 测试：往 IO0 写 0x55，循环
extern unsigned char REGISTER_IO0;
#define IO0 REGISTER_IO0

void main() {
    IO0 = 0x55;
    while (1);
}
