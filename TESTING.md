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

### Full Test Suite by Category

```bash
# All tests
./test/scripts/test-all.sh

# Individual categories
./test/scripts/test-cpu.sh      # CPU instruction, timing, interrupt tests
./test/scripts/test-ppu.sh      # VBlank/NMI, sprite 0, sprite overflow tests
./test/scripts/test-apu.sh      # APU registers, DMC, reset behavior tests
./test/scripts/test-mappers.sh  # MMC1, MMC3 mapper tests
```

### Running Individual Tests

Use the CLI directly:

```bash
PLTCOLLECTS="$PWD:" /opt/homebrew/bin/racket main.rkt \
    --rom test/roms/nes-test-roms/instr_test-v5/rom_singles/01-basics.nes \
    --headless \
    --frames 3000 \
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

## Current Test Results

*Last updated: 2024-12-27*

### CPU Tests

| Test | Status | Notes |
|------|--------|-------|
| 01-basics.nes | PASS | |
| 02-implied.nes | INCONCLUSIVE | Needs more frames |
| 03-immediate.nes | INCONCLUSIVE | Needs more frames |
| 04-zero_page.nes | INCONCLUSIVE | Needs more frames |
| 05-zp_xy.nes | INCONCLUSIVE | Needs more frames |
| 06-absolute.nes | INCONCLUSIVE | Needs more frames |
| 07-abs_xy.nes | INCONCLUSIVE | Needs more frames |
| 08-ind_x.nes | INCONCLUSIVE | Needs more frames |
| 09-ind_y.nes | INCONCLUSIVE | Needs more frames |
| 10-branches.nes | FAIL | BCC instruction |
| 11-stack.nes | FAIL | PHA instruction |
| 12-jmp_jsr.nes | FAIL | JMP instruction |
| 13-rts.nes | FAIL | RTS instruction |
| 14-rti.nes | FAIL | RTI instruction |
| 15-brk.nes | PASS | |
| 16-special.nes | PASS | |

**Summary: 3 passed, 5 failed, 8 inconclusive**

### PPU Tests

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
| Sprite 0 hit (all) | INCONCLUSIVE | Need more frames |
| Sprite overflow (all) | INCONCLUSIVE | Need more frames |

**Summary: 2 passed, 8 failed, 21 inconclusive**

### APU Tests

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
| DMC tests (all) | INCONCLUSIVE | Need more frames |
| APU reset (all) | FAIL | Reset behavior |

**Summary: 3 passed, 11 failed, 4 inconclusive**

### Overall Summary

| Category | Passed | Failed | Inconclusive |
|----------|--------|--------|--------------|
| CPU | 3 | 5 | 8 |
| PPU | 2 | 8 | 21 |
| APU | 3 | 11 | 4 |
| **Total** | **8** | **24** | **33** |

## Known Issues

1. **Branch/Stack instructions** — Tests 10-14 fail, suggesting issues with BCC, PHA, JMP, RTS, RTI
2. **NMI timing** — NMI occurs one instruction too early
3. **Odd frame skip** — Clock skip timing relative to BG enable is wrong
4. **APU timing** — Frame IRQ and length counter timing off
5. **DMC** — Buffer/rate implementation needs work

## Adding New Tests

1. Add the test ROM to the appropriate script in `test/scripts/`
2. Use the `run_test` function from `test-common.sh`:
   ```bash
   run_test "$TEST_ROMS/path/to/test.nes" 3000 "Test description"
   ```
3. The second argument is the frame count (start with 3000, increase if inconclusive)
