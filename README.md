# 74HC-Chiptune
A 4-channel wavetable synthesizer using only 74HC logic, SRAM, and Flash ROM. A lookup-table accumulator replaces all arithmetic: 74283 adders do phase accumulation, a pre-computed 39SF040 ROM handles wave×level×vol, and 62256 SRAM stores registers. 9 ICs, parallel bus interface.
