#!/usr/bin/env python3
# gen_spfm_decode_rom.py — 生成 SPFM 总线译码 ROM (39SF040)
#
# 地址 A3..A0 = {CS_n, WR_n, A0, RST_n}
# 输出 DQ2..DQ0 = {le, data_wr_n, addr_wr_n}
# 默认 0x03 (le=0, data_wr_n=1, addr_wr_n=1, 无操作)
# CS=0, WR=0, RST=1, A0=0 → 0x06 (le=1, addr_wr_n=0)
# CS=0, WR=0, RST=1, A0=1 → 0x05 (le=1, data_wr_n=0)

def main():
    rom = bytearray(524288)  # 512KB, 全 0x00 初始化

    # 默认值: 所有可能地址都填 0x03 (无操作)
    for i in range(524288):
        rom[i] = 0x03

    # 写地址: A3=0, A2=0, A1=0, A0=1 (CS=0, WR=0, A0=0, RST=1)
    # → 输出 le=1, data_wr_n=1, addr_wr_n=0 = 0b110 = 0x06
    rom[0b0001] = 0x06

    # 写数据: A3=0, A2=0, A1=1, A0=1 (CS=0, WR=0, A0=1, RST=1)
    # → 输出 le=1, data_wr_n=0, addr_wr_n=1 = 0b101 = 0x05
    rom[0b0011] = 0x05

    with open("rom/spfm_decode.hex", "w") as f:
        for b in rom:
            f.write(f"{b:02X}\n")

    print(f"Written spfm_decode.hex ({len(rom)} bytes)")
    print("Mapping:")
    for addr in range(16):
        cs, wr, a0, rst = (addr >> 3) & 1, (addr >> 2) & 1, (addr >> 1) & 1, addr & 1
        val = rom[addr]
        le = (val >> 2) & 1
        dw = (val >> 1) & 1
        aw = val & 1
        desc = ""
        if cs == 0 and wr == 0 and rst == 1 and a0 == 0:
            desc = " ← WRITE ADDR"
        elif cs == 0 and wr == 0 and rst == 1 and a0 == 1:
            desc = " ← WRITE DATA"
        print(f"  {addr:04b} (CS={cs} WR={wr} A0={a0} RST={rst}) → 0x{val:02X} (le={le} data_wr_n={dw} addr_wr_n={aw}){desc}")

if __name__ == "__main__":
    main()
