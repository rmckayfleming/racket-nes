# TESTING.md — NES Emulator Test Suite

This document describes how to run the automated test suite for verifying emulator accuracy.

## Setup

### 1. Clone Test ROM Repositories

```bash
cd test/roms
git clone https://github.com/christopherpow/nes-test-roms.git
git clone https://github.com/bbbradsmith/nes-audio-tests.git
```

### 2. Directory Structure

After cloning:
```
test/
├── roms/
│   ├── nes-test-roms/      # Main test ROM collection
│   ├── nes-audio-tests/    # Audio-specific tests
│   ├── nestest.nes         # CPU validation (already present)
│   └── ...                 # Commercial ROMs for smoke testing
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

## Running Tests

### Quick Smoke Test (Recommended for Development)

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

*Last updated: 2025-12-27*

### Summary

| Category | Passed | Failed |
|----------|--------|--------|
| CPU      | 16     | 0      |
| PPU      | 2      | 8      |
| APU      | 3      | 5      |
| Mappers  | 1      | 5      |
| **Total**| **22** | **18** |

### CPU Tests (instr_test-v5)

| Test | Status | Notes |
|------|--------|-------|
| 01-basics.nes | PASS | |
| 02-implied.nes | PASS | |
| 03-immediate.nes | PASS | |
| 04-zero_page.nes | PASS | |
| 05-zp_xy.nes | PASS | |
| 06-absolute.nes | PASS | |
| 07-abs_xy.nes | PASS | |
| 08-ind_x.nes | PASS | |
| 09-ind_y.nes | PASS | |
| 10-branches.nes | PASS | |
| 11-stack.nes | PASS | |
| 12-jmp_jsr.nes | PASS | |
| 13-rts.nes | PASS | |
| 14-rti.nes | PASS | |
| 15-brk.nes | PASS | |
| 16-special.nes | PASS | |

### PPU Tests (ppu_vbl_nmi)

| Test | Status | Notes |
|------|--------|-------|
| 01-vbl_basics.nes | PASS | |
| 02-vbl_set_time.nes | FAIL | VBlank set timing |
| 03-vbl_clear_time.nes | PASS | |
| 04-nmi_control.nes | FAIL | NMI timing after instruction |
| 05-nmi_timing.nes | FAIL | |
| 06-suppression.nes | FAIL | |
| 07-nmi_on_timing.nes | FAIL | |
| 08-nmi_off_timing.nes | FAIL | |
| 09-even_odd_frames.nes | FAIL | Odd frame skip timing |
| 10-even_odd_timing.nes | FAIL | |

### APU Tests (apu_test)

| Test | Status | Notes |
|------|--------|-------|
| 1-len_ctr.nes | PASS | |
| 2-len_table.nes | PASS | |
| 3-irq_flag.nes | PASS | |
| 4-jitter.nes | FAIL | Frame IRQ timing |
| 5-len_timing.nes | FAIL | Length counter timing |
| 6-irq_flag_timing.nes | FAIL | IRQ flag timing |
| 7-dmc_basics.nes | FAIL | DMC buffer behavior |
| 8-dmc_rates.nes | FAIL | DMC rate timing |

### Mapper Tests (mmc3_test)

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

1. **NMI timing** — NMI occurs one instruction too early
2. **Odd frame skip** — Clock skip timing relative to BG enable is wrong
3. **APU timing** — Frame IRQ and length counter timing off
4. **DMC** — Buffer/rate implementation needs work
5. **MMC3 IRQ** — Scanline counter not working correctly

## Adding New Tests

1. Ensure the test uses the Blargg `$6000` protocol
2. Add the test ROM to the appropriate script in `test/scripts/`
3. Use `smart_test` function from `test-common.sh`:
   ```bash
   smart_test "$TEST_ROMS/path/to/test.nes" 5000 "Test description"
   ```
4. The second argument is the frame count (start with 5000)
