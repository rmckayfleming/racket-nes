# TESTING.md — NES Emulator Test Suite

This document describes how to run the automated test suite for verifying emulator accuracy.

## Quick Start: AccuracyCoin

The **AccuracyCoin** test ROM is the most comprehensive single test for NES accuracy, covering 131 tests across CPU, PPU, APU, and timing. This should be your primary validation tool.

```bash
# Run all tests, show failures only (Mode A - instruction-stepped)
PLTCOLLECTS="$PWD:" racket test/harness/accuracy-coin.rkt --failures

# Run in Mode B (cycle-accurate) to test timing precision
PLTCOLLECTS="$PWD:" racket test/harness/accuracy-coin.rkt --failures --tick

# Show all results including passes
PLTCOLLECTS="$PWD:" racket test/harness/accuracy-coin.rkt --detailed
```

### Current AccuracyCoin Results

| Mode | Passed | Failed | Draw | Notes |
|------|--------|--------|------|-------|
| Mode A | 83 | 46 | 5 | Instruction-stepped timing |
| Mode B | 69 | 61 | 5 | Cycle-accurate timing |

Mode B has additional failures in illegal opcode page-crossing timing and instruction timing tests.

## Setup

### 1. Clone Test ROM Repositories

```bash
cd test/roms
git clone https://github.com/christopherpow/nes-test-roms.git
git clone https://github.com/bbbradsmith/nes-audio-tests.git
git clone https://github.com/100thCoin/AccuracyCoin.git accuracy-coin
```

### 2. Directory Structure

After cloning:
```
test/
├── roms/
│   ├── accuracy-coin/      # AccuracyCoin comprehensive test (131 tests)
│   ├── nes-test-roms/      # Main test ROM collection
│   ├── nes-audio-tests/    # Audio-specific tests
│   ├── nestest.nes         # CPU validation (already present)
│   └── ...                 # Commercial ROMs for smoke testing
├── harness/
│   ├── accuracy-coin.rkt   # AccuracyCoin test harness
│   ├── nestest.rkt         # nestest CPU validation harness
│   └── run-rom.rkt         # Generic ROM runner
├── scripts/
│   ├── test-all.sh         # Run all test categories
│   ├── test-quick.sh       # Fast smoke test (~8 tests)
│   ├── test-cpu.sh         # CPU instruction/timing tests
│   ├── test-ppu.sh         # PPU tests
│   ├── test-apu.sh         # APU tests
│   └── test-mappers.sh     # Mapper tests
└── reference/
    └── nestest.log         # Reference trace for nestest
```

## Test Harnesses

### AccuracyCoin Harness (Recommended)

The AccuracyCoin harness automatically runs all 131 tests and parses results from the screen:

```bash
# Show only failures
PLTCOLLECTS="$PWD:" racket test/harness/accuracy-coin.rkt --failures

# Show all results
PLTCOLLECTS="$PWD:" racket test/harness/accuracy-coin.rkt --detailed

# Use Mode B (cycle-accurate) timing
PLTCOLLECTS="$PWD:" racket test/harness/accuracy-coin.rkt --failures --tick
```

Test result statuses:
- **PASS**: Test passed
- **FAIL N**: Test failed with error code N
- **DRAW**: Inconclusive (power-on state tests depend on random RAM)

### nestest Harness

CPU instruction validation against reference log:

```bash
PLTCOLLECTS="$PWD:" racket test/harness/nestest.rkt
```

## Running Blargg Tests

### Quick Smoke Test

Run 8 essential tests to catch obvious regressions:

```bash
./test/scripts/test-quick.sh

# Run in parallel for ~4x speedup
./test/scripts/test-quick.sh -j
```

### Full Test Suite

```bash
# All tests (use -j for parallel execution)
./test/scripts/test-all.sh -j

# Individual categories
./test/scripts/test-cpu.sh -j
./test/scripts/test-ppu.sh -j
./test/scripts/test-apu.sh -j
./test/scripts/test-mappers.sh -j
```

### Running Individual Tests

Use the CLI directly:

```bash
PLTCOLLECTS="$PWD:" /opt/homebrew/bin/racket main.rkt \
    --rom test/roms/nes-test-roms/instr_test-v5/rom_singles/01-basics.nes \
    --headless \
    --frames 5000 \
    --test-addr 0x6000
```

Exit codes: `0` = pass, `1` = fail, `2` = inconclusive

## CLI Flags for Testing

| Flag | Description |
|------|-------------|
| `--headless` | Run without video/audio output |
| `--frames N` | Run for N frames then exit |
| `--steps N` | Run for N CPU steps then exit |
| `--test-addr HEX` | Check Blargg test result at address (e.g., `0x6000`) |
| `--pc HEX` | Override initial PC (e.g., `0xC000` for nestest) |
| `--trace` | Enable CPU trace output |

## Test Result Protocol

Most test ROMs use the Blargg protocol:

| Address | Meaning |
|---------|---------|
| `$6000` | Status: `$80` = running, `$00` = passed, `$01+` = failed |
| `$6001-$6003` | Magic bytes `$DE $B0 $61` (validates test initialized) |
| `$6004+` | Human-readable error message (null-terminated) |

Tests that crash with an illegal opcode while status is still `$80` are treated as failures.

## Current Test Results

*Last updated: 2025-12-31*

### AccuracyCoin Detailed Results (Mode A)

The AccuracyCoin ROM provides the most granular view of emulator accuracy. Current failures:

#### CPU Timing
| Test | Error | Issue |
|------|-------|-------|
| DUMMY READ CYCLES | 1 | Dummy read timing |
| DUMMY WRITE CYCLES | 2 | Dummy write timing |
| OPEN BUS | 1 | Open bus behavior |
| ALL NOP INSTRUCTIONS | 2 | Unofficial NOP timing |
| IMPLIED DUMMY READS | 2 | Implied mode dummy reads |
| JSR EDGE CASES | 2 | JSR timing edge cases |

#### Illegal Opcodes
| Test | Error | Issue |
|------|-------|-------|
| $93 SHA INDIRECT'Y | 0 | SHA timing |
| $9F SHA ABSOLUTE'Y | 0 | SHA timing |
| $9B SHS ABSOLUTE'Y | 1 | SHS timing |
| $9C SHY ABSOLUTE'X | 1 | SHY timing |
| $9E SHX ABSOLUTE'Y | 1 | SHX timing |

#### Interrupts
| Test | Error | Issue |
|------|-------|-------|
| INTERRUPT FLAG LATENCY | 2 | I flag latency |
| NMI OVERLAP BRK | 2 | NMI/BRK interaction |
| NMI OVERLAP IRQ | 1 | NMI/IRQ interaction |

#### DMA
| Test | Error | Issue |
|------|-------|-------|
| DMA + OPEN BUS | 1 | DMA open bus behavior |
| DMA + $2007 READ | 2 | DMA during VRAM read |
| DMA + $2007 WRITE | 1 | DMA during VRAM write |
| DMA + $4015 READ | 2 | DMA during APU status read |
| DMA + $4016 READ | 1 | DMA during controller read |
| DMC DMA BUS CONFLICTS | 2 | DMC DMA conflicts |
| DMC DMA + OAM DMA | 1 | DMC/OAM DMA interaction |
| EXPLICIT DMA ABORT | 1 | DMA abort behavior |
| IMPLICIT DMA ABORT | 1 | DMA abort behavior |

#### APU
| Test | Error | Issue |
|------|-------|-------|
| FRAME COUNTER IRQ | 6 | Frame counter IRQ timing |
| FRAME COUNTER 4-STEP | 1 | 4-step mode timing |
| FRAME COUNTER 5-STEP | 1 | 5-step mode timing |
| DELTA MODULATION CHANNEL | 0 | DMC implementation |
| APU REGISTER ACTIVATION | 1 | Register enable timing |

#### Controller
| Test | Error | Issue |
|------|-------|-------|
| CONTROLLER STROBING | 3 | Strobe timing |
| CONTROLLER CLOCKING | 5 | Shift register clocking |

#### PPU
| Test | Error | Issue |
|------|-------|-------|
| PPU REGISTER OPEN BUS | 4 | Open bus decay |
| PALETTE RAM QUIRKS | 5 | Palette mirroring/behavior |
| RENDERING FLAG BEHAVIOR | 1 | BG/sprite enable timing |
| VBLANK BEGINNING | 1 | VBlank set timing |
| NMI TIMING | 1 | NMI edge timing |
| NMI SUPPRESSION | 1 | NMI suppression window |
| NMI DISABLED AT VBLANK | 1 | NMI enable at VBlank edge |
| ARBITRARY SPRITE ZERO | 2 | Sprite 0 hit timing |
| MISALIGNED OAM BEHAVIOR | 1 | OAM access alignment |
| ADDRESS $2004 BEHAVIOR | 1 | OAMDATA read behavior |
| OAM CORRUPTION | 2 | OAM corruption during rendering |
| INC $4014 | 1 | OAM DMA page increment |
| ATTRIBUTES AS TILES | 1 | Attribute table rendering |
| STALE BG SHIFT REGISTERS | 3 | BG shift register reload |
| BG SERIAL IN | 2 | BG pattern shift |
| SPRITES ON SCANLINE 0 | 2 | Scanline 0 sprite evaluation |

### Blargg Test Results

#### CPU Tests (instr_test-v5) — All Passing

| Test | Status |
|------|--------|
| 01-basics.nes | PASS |
| 02-implied.nes | PASS |
| 03-immediate.nes | PASS |
| 04-zero_page.nes | PASS |
| 05-zp_xy.nes | PASS |
| 06-absolute.nes | PASS |
| 07-abs_xy.nes | PASS |
| 08-ind_x.nes | PASS |
| 09-ind_y.nes | PASS |
| 10-branches.nes | PASS |
| 11-stack.nes | PASS |
| 12-jmp_jsr.nes | PASS |
| 13-rts.nes | PASS |
| 14-rti.nes | PASS |
| 15-brk.nes | PASS |
| 16-special.nes | PASS |

#### PPU Tests (ppu_vbl_nmi)

| Test | Status | Notes |
|------|--------|-------|
| 01-vbl_basics.nes | PASS | |
| 02-vbl_set_time.nes | FAIL | VBlank set timing |
| 03-vbl_clear_time.nes | PASS | |
| 04-nmi_control.nes | PASS | |
| 05-nmi_timing.nes | FAIL | |
| 06-suppression.nes | FAIL | |
| 07-nmi_on_timing.nes | FAIL | |
| 08-nmi_off_timing.nes | FAIL | |
| 09-even_odd_frames.nes | FAIL | Odd frame skip timing |
| 10-even_odd_timing.nes | FAIL | |

#### APU Tests (apu_test)

| Test | Status | Notes |
|------|--------|-------|
| 1-len_ctr.nes | FAIL | Length table/timing/$4015 issue |
| 2-len_table.nes | PASS | |
| 3-irq_flag.nes | FAIL | IRQ flag behavior |
| 4-jitter.nes | FAIL | Frame IRQ timing |
| 5-len_timing.nes | FAIL | Length counter timing |
| 6-irq_flag_timing.nes | FAIL | IRQ flag timing |
| 7-dmc_basics.nes | FAIL | DMC buffer behavior |
| 8-dmc_rates.nes | FAIL | DMC rate timing |

#### Mapper Tests (mmc3_test)

| Test | Status | Notes |
|------|--------|-------|
| 1-clocking.nes | FAIL | IRQ/A12 clocking |
| 2-details.nes | FAIL | Counter reload |
| 3-A12_clocking.nes | FAIL | A12 change detection |
| 4-scanline_timing.nes | FAIL | Scanline 0 IRQ timing |
| 5-MMC3.nes | FAIL | Reload behavior |
| 6-MMC6.nes | PASS | |

## Tests Requiring Visual Inspection

Some older test ROMs don't use the Blargg `$6000` protocol and require visual inspection:

- `sprite_hit_tests_2005` - Sprite 0 hit tests
- `sprite_overflow_tests` - Sprite overflow tests
- `blargg_ppu_tests_2005` - Palette RAM, sprite RAM, VRAM access
- `branch_timing_tests` - Branch timing
- `cpu_dummy_reads/writes` - Dummy read/write tests
- `dmc_tests` - DMC tests
- `apu_reset` - APU reset tests (require reset button)
- `MMC1_A12` - MMC1 A12 test

## Known Issues

Based on AccuracyCoin results, the main areas needing work are:

### High Priority (Affects Game Compatibility)

1. **DMA timing** — OAM DMA conflicts with PPU/APU register reads, DMC DMA bus conflicts
2. **NMI timing** — Suppression window, edge timing, overlap with BRK/IRQ
3. **Controller timing** — Strobe and shift register clocking precision
4. **PPU register behavior** — Open bus decay, palette RAM quirks

### Medium Priority (Accuracy)

5. **CPU dummy reads/writes** — Timing of dummy cycles in various addressing modes
6. **Illegal opcode timing** — SHA/SHX/SHY/SHS page-crossing behavior
7. **Frame counter** — IRQ timing, 4-step/5-step mode transitions
8. **Sprite evaluation** — OAM corruption during rendering, scanline 0 behavior

### Lower Priority (Edge Cases)

9. **Open bus behavior** — CPU and PPU open bus emulation
10. **JSR edge cases** — Stack timing edge cases
11. **MMC3 IRQ** — Scanline counter A12 clocking

## Adding New Tests

1. Ensure the test uses the Blargg `$6000` protocol
2. Add the test ROM to the appropriate script in `test/scripts/`
3. Use `smart_test` function from `test-common.sh`:
   ```bash
   smart_test "$TEST_ROMS/path/to/test.nes" 5000 "Test description"
   ```
4. The second argument is the frame count (start with 5000)
