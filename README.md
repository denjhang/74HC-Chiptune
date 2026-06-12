# 74HC-Chiptune

A 4-channel wavetable synthesizer using only 74HC logic, SRAM, and Flash ROM. A lookup-table accumulator replaces all arithmetic: 74283 adders do phase accumulation, a pre-computed 39SF040 ROM handles wave×level×vol, and 62256 SRAM stores registers. 9 ICs, parallel bus interface.

## Architecture

### Lookup-Table Accumulator

The core idea: **ROM replaces all multiplication**. The 39SF040 Flash ROM stores pre-computed `wave[idx] × (level+1) × (vol+1) >> 9` for every combination. The 74HC chips only do address generation and phase accumulation — no hardware multiplier needed.

```
Each sample cycle:
  1. phase += step              (74283 × 2, 16-bit add)
  2. idx = phase[11:5]          (direct wiring, 7-bit)
  3. ROM lookup → DAC output    (39SF040, one read)
  4. Envelope update            (counter + state machine)
```

### Chip Count — 9 ICs Total

| Chip | Qty | Function |
|------|-----|----------|
| 74161 | 1 | Micro-operation step counter (3-bit) |
| 74283 | 2 | 16-bit phase accumulator (8-bit × 2, carry-chain) |
| 74377 | 2 | Address latch + data latch |
| 74157 | 1 | Address mux (ROM/RAM select) |
| 74138 + 7404 | 2 | Control signal decode |
| 39SF040 | 1 | 512KB Flash — all lookup tables |
| 62256 | 1 | 32KB SRAM — all registers |

### ROM Table (39SF040 — 512KB)

Address mapping: `{wave_idx[2:0], level[3:0], vol[4:0], phase[11:5]}` = 19-bit

| Region | Size | Content |
|--------|------|---------|
| 0x00000 - 0x5FFFF | 384KB | Wave × level × vol lookup (6 waves × 128pt × 16lvl × 32vol) |
| 0x60000 - 0x7FFFF | 128KB | Free (reserved for expansion) |

### RAM Register Map (62256 — 32KB)

Each channel uses 16 bytes. 4 channels = 64 bytes. 32KB has room for 2048 channels.

| Offset | Field | Width | Description |
|--------|-------|-------|-------------|
| 0x00 | phase_lo | 8 | Phase low byte |
| 0x01 | phase_hi | 8 | Phase high byte |
| 0x02 | step_lo | 8 | Frequency step low byte |
| 0x03 | step_hi | 8 | Frequency step high byte |
| 0x04 | level | 4 | Envelope level (0-15) |
| 0x05 | env_state | 3 | Envelope state (0=off, 1=attack, 2=sustain, 3=release) |
| 0x06 | env_cnt | 8 | Envelope counter |
| 0x07 | vol | 5 | Volume (0-31) |
| 0x08 | dac_out | 8 | DAC output value |
| 0x09 | wave_idx | 3 | Waveform select (0-5) |
| 0x0A | env_rate | 8 | Envelope speed (set by host) |

### Waveforms (128-point, ±31 signed)

| Index | Name | Description |
|-------|------|-------------|
| 0 | sqr | Square wave 50% |
| 1 | sq12 | Square wave 12.5% (GB duty) |
| 2 | sq25 | Square wave 25% (GB duty) |
| 3 | sine | Sine wave |
| 4 | saw | Sawtooth |
| 5 | noise | Pre-generated white noise |

### ADSR Envelope

4 states: attack → sustain → release (simplified from STC32G reference).

- **level**: 0-15 (4-bit, AY-3-8910 style)
- **vol**: 0-31 (5-bit, host-controlled master volume)
- **env_rate**: 8-bit counter threshold, written by host
- attack ramps level from 0 to 15, sustain holds, release decays to 0

## Parameters (Aligned with STC32G)

All parameters match the STC32G port (`wt.c`), verified on real hardware:

- **Phase**: 16-bit accumulator
- **Index**: `phase[11:5]` (7-bit, 128-point waveform)
- **Step**: `freq × 8192 / sample_rate`
- **Output**: `wave × (level+1) × (vol+1) >> 9`
- **Sample rate**: 32051 Hz (simulation), configurable via host

### Common Note Steps (32051 Hz)

| Note | Freq (Hz) | Step |
|------|-----------|------|
| C4 | 261.6 | 67 |
| D4 | 293.7 | 75 |
| E4 | 329.6 | 84 |
| F4 | 349.2 | 89 |
| G4 | 392.0 | 100 |
| A4 | 440.0 | 112 |
| B4 | 493.9 | 126 |
| C5 | 523.3 | 134 |

## Simulation Verification

### Build & Run

```bash
export PATH="/c/Users/denjhang/iverilog/bin:$PATH"

# Compile
iverilog -o tb/wt_rom_tb.vvp tb/wt_rom_tb.v

# Run (outputs wt_output.csv)
vvp tb/wt_rom_tb.vvp

# Convert to WAV
python3 csv_to_wav.py wt_output.csv
```

### Test Results

| Test | Result |
|------|--------|
| sine C4 (261.6 Hz) | 261.6 Hz, zero-crossing verified |
| sqr A4 (440.0 Hz) | 437.6 Hz (0.5% error) |
| saw C4 (261.6 Hz) | 260.9 Hz (0.3% error) |
| C major chord (C4+E4+G4) | DFT confirms all three frequencies |
| Multi-waveform (sqr+saw+noise+sine) | 4 channels independent |
| Envelope attack | 0 → peak, smooth ramp |
| Envelope release | Peak → 0, smooth decay |

## Bus Interface (Host MCU)

Parallel bus, compatible with 8-bit MCU:

| Signal | Direction | Description |
|--------|-----------|-------------|
| A0-A7 | In | Register address |
| D0-D7 | Bidirectional | Data bus |
| /CS | In | Chip select (active low) |
| /WR | In | Write strobe (active low) |
| /RD | In | Read strobe (active low) |
| /RST | In | Reset (active low) |

The host MCU writes step/volume/envelope parameters and triggers note-on/note-off. No MIDI note lookup on the synthesizer — the host calculates step values for flexible pitch bend, vibrato, and fine tuning.

## Project Structure

```
74HC-Chiptune/
├── README.md
├── csv_to_wav.py          # CSV → WAV converter
├── rtl/
│   └── wt_top.v           # RTL with parallel bus interface
├── tb/
│   ├── wt_fast_tb.v       # Behavioral testbench (single-channel verification)
│   ├── wt_top_tb.v        # Bus interface testbench
│   └── wt_rom_tb.v        # 4-channel lookup-table testbench (current)
├── rom/
│   ├── wt_39sf040.bin     # 512KB Flash ROM binary
│   ├── wt_39sf040.hex     # Hex format for simulation
│   ├── sin_64.hex         # 64-point sine (legacy)
│   └── sin_128.hex        # 128-point sine (from STC32G)
├── docs/
│   ├── build-iverilog.md  # Iverilog build instructions
│   ├── tools-and-usage.md # Toolchain setup
│   ├── wt-development.md  # WT development log
│   └── lut-mcu-concept.md # LUT-MCU concept (future work)
└── ice-chips-verilog-main/ # 74HC Verilog library
```

## References

- STC32G port: `D:\working\vscode-projects\STC_Chiptune\STC32G12K128\wt.c` — 16-channel, 128-point, 14-waveform, ADSR. Authoritative reference for all parameters.
- Arduino original: Keiji Katahira's ArduinoUno_wavetable_synthesis — single-channel, 64-point.
- Gigatron TTL: http://gigatron.io/ — inspired the lookup-table MCU concept.
- SCC (K051649): Konami's 5-channel, 32-point waveform synth, 16-level volume.

## License

MIT
