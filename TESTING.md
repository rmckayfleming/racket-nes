# TESTING.md — NES Emulator Test Plan

This document provides a systematic test plan for verifying NES emulator accuracy. It is designed to be followed by Claude Code or other AI development agents.

## Philosophy

Testing an emulator differs from testing typical software. The "specification" is real hardware behavior, which is documented through community efforts and encoded in test ROMs. Our approach:

1. **Test ROMs are the source of truth** — Community-developed test ROMs encode known hardware behavior. Passing them means matching real NES behavior.
2. **Progressive complexity** — Start with CPU tests, then PPU, then APU. Later subsystems depend on earlier ones being correct.
3. **Memory-based pass/fail first** — Most test ROMs write results to memory ($6000 region). This enables headless CI without screenshots.
4. **Visual regression for rendering** — Screenshot comparison catches subtle PPU bugs that test ROMs might miss.
5. **Automation over manual testing** — Every test should be runnable via `raco test` or a shell command.

---

## 1. Test ROM Setup

### 1.1 Acquire Test ROMs

The primary test ROM collection lives at `christopherpow/nes-test-roms`. Clone it into the test directory:

```bash
cd test/roms
git clone https://github.com/christopherpow/nes-test-roms.git
```

After cloning, the structure should be:
```
test/roms/
├── nes-test-roms/          # Cloned test ROM collection
│   ├── cpu/
│   ├── ppu/
│   ├── apu/
│   └── ...
├── nestest.nes             # Keep this for quick CPU validation
├── smb.nes                 # Commercial ROMs for smoke testing
└── ...
```

### 1.2 Additional Test Resources

For audio testing, also clone:
```bash
cd test/roms
git clone https://github.com/bbbradsmith/nes-audio-tests.git
```

### 1.3 Reference Screenshots

Create a directory for baseline screenshots:
```bash
mkdir -p test/reference/screenshots
```

Generate reference screenshots using Mesen (the accuracy reference):
- Install Mesen2 or use its CLI mode
- For each visual test, capture the frame at a specific cycle/frame count
- Save as PNG in `test/reference/screenshots/`

---

## 2. Test Harness Requirements

The emulator must support these CLI modes for automated testing:

### 2.1 Required CLI Flags

```bash
# Run ROM headlessly for N frames, exit with status based on memory
racket main.rkt --rom <path> --headless --frames <N> --test-addr <hex>

# Run ROM and dump screenshot at frame N
racket main.rkt --rom <path> --headless --frames <N> --screenshot-out <path.png>

# Run ROM and dump trace (nestest format)
racket main.rkt --rom <path> --headless --steps <N> --trace --trace-out <path.log>

# Run ROM with initial PC override (for nestest automation mode)
racket main.rkt --rom <path> --headless --pc 0xC000 --steps <N>
```

### 2.2 Test Address Protocol (Blargg Standard)

Most test ROMs follow this protocol for reporting results:

| Address | Meaning |
|---------|---------|
| `$6000` | Status: `$80` = running, `$00` = passed, `$01`+ = failed |
| `$6001-$6003` | Magic bytes `$DE $B0 $61` (validates test ROM initialized) |
| `$6004+` | Human-readable result text (null-terminated) |

**Pass criteria**: After N frames, `$6000 == $00` and magic bytes are present.

### 2.3 Implementing Test Harness Support

If not already present, add to `main.rkt`:

```racket
;; After running specified frames, check test result
(define (check-test-result nes test-addr)
  (define status (bus-read (nes-cpu-bus nes) test-addr))
  (define magic1 (bus-read (nes-cpu-bus nes) (+ test-addr 1)))
  (define magic2 (bus-read (nes-cpu-bus nes) (+ test-addr 2)))
  (define magic3 (bus-read (nes-cpu-bus nes) (+ test-addr 3)))
  (cond
    [(not (and (= magic1 #xDE) (= magic2 #xB0) (= magic3 #x61)))
     (displayln "FAIL: Magic bytes not found (test ROM may not have initialized)")
     1]
    [(= status #x00)
     (displayln "PASS")
     0]
    [(= status #x80)
     (displayln "FAIL: Test still running (increase frame count?)")
     1]
    [else
     (displayln (format "FAIL: Status code ~a" status))
     ;; Read and display error message from $6004+
     (display-test-message nes (+ test-addr 4))
     1]))
```

---

## 3. Test Categories and Progression

Run tests in this order. Later categories depend on earlier ones passing.

### 3.1 CPU Tests (Foundation)

**Prerequisites**: None  
**Run first**: These must pass before any other tests are meaningful.

#### 3.1.1 nestest (Official Opcodes)

The essential first test. Run in automation mode (PC=$C000) to bypass PPU requirements.

```bash
racket main.rkt --rom test/roms/nestest.nes --headless --pc 0xC000 --steps 8991 --trace --trace-out /tmp/nestest-trace.log
```

**Pass criteria**: 
- All 8991 steps complete
- Trace matches `test/reference/nestest.log` exactly
- Memory $0002 == $00 and $0003 == $00 at completion

**On failure**: Diff the trace against reference to find first divergence:
```bash
diff -u test/reference/nestest.log /tmp/nestest-trace.log | head -50
```

#### 3.1.2 Blargg's cpu_instrs

Comprehensive instruction tests, broken into subtests:

```
test/roms/nes-test-roms/cpu_instrs/individual/
├── 01-basics.nes
├── 02-implied.nes
├── 03-immediate.nes
├── 04-zero_page.nes
├── 05-zp_xy.nes
├── 06-absolute.nes
├── 07-abs_xy.nes
├── 08-ind_x.nes
├── 09-ind_y.nes
├── 10-branches.nes
├── 11-stack.nes
├── 12-jmp_jsr.nes
├── 13-rts.nes
├── 14-rti.nes
├── 15-brk.nes
└── 16-special.nes
```

**Run each**:
```bash
racket main.rkt --rom test/roms/nes-test-roms/cpu_instrs/individual/01-basics.nes \
    --headless --frames 3000 --test-addr 0x6000
```

**Pass criteria**: $6000 == $00 after ~3000 frames (some tests need more)

**Frame counts** (approximate, may need adjustment):
- 01-basics: 2000 frames
- 02-implied through 09-ind_y: 3000 frames each
- 10-branches: 3000 frames
- 11-stack through 16-special: 3000 frames each

**All-in-one ROM**: `cpu_instrs/cpu_instrs.nes` runs all tests sequentially (~30000 frames)

#### 3.1.3 CPU Timing Tests

After instructions pass, verify cycle timing:

```bash
# Instruction timing
racket main.rkt --rom test/roms/nes-test-roms/cpu_timing_test6/cpu_timing_test.nes \
    --headless --frames 5000 --test-addr 0x6000

# Branch timing
racket main.rkt --rom test/roms/nes-test-roms/branch_timing_tests/1.Branch_Basics.nes \
    --headless --frames 2000 --test-addr 0x6000
```

---

### 3.2 PPU Tests (Visual Correctness)

**Prerequisites**: CPU tests passing

#### 3.2.1 VBlank and NMI Timing

Critical for games to run at all:

```
test/roms/nes-test-roms/ppu_vbl_nmi/
├── 01-vbl_basics.nes
├── 02-vbl_set_time.nes
├── 03-vbl_clear_time.nes
├── 04-nmi_control.nes
├── 05-nmi_timing.nes
├── 06-suppression.nes
├── 07-nmi_on_timing.nes
├── 08-nmi_off_timing.nes
├── 09-even_odd_frames.nes
└── 10-even_odd_timing.nes
```

**Run each**:
```bash
racket main.rkt --rom test/roms/nes-test-roms/ppu_vbl_nmi/01-vbl_basics.nes \
    --headless --frames 1500 --test-addr 0x6000
```

**Difficulty note**: Tests 06-10 are notoriously hard. It's acceptable to have 01-05 passing for basic compatibility.

#### 3.2.2 Sprite Tests

```bash
# Sprite 0 hit
racket main.rkt --rom test/roms/nes-test-roms/sprite_hit_tests/01.Basics.nes \
    --headless --frames 2000 --test-addr 0x6000

# Sprite overflow
racket main.rkt --rom test/roms/nes-test-roms/sprite_overflow_tests/1.Basics.nes \
    --headless --frames 2000 --test-addr 0x6000
```

#### 3.2.3 PPU Register Tests

```bash
racket main.rkt --rom test/roms/nes-test-roms/ppu_open_bus/ppu_open_bus.nes \
    --headless --frames 1500 --test-addr 0x6000
```

#### 3.2.4 Visual Regression Tests (Screenshots)

For rendering correctness beyond what test ROMs check:

1. **Generate baseline** (once, using Mesen as reference):
   ```bash
   # Use Mesen CLI or manually capture at specific frame
   mesen-cli --rom test/roms/smb.nes --frames 300 --screenshot test/reference/screenshots/smb-title.png
   ```

2. **Test against baseline**:
   ```bash
   racket main.rkt --rom test/roms/smb.nes --headless --frames 300 \
       --screenshot-out /tmp/smb-title.png
   
   # Compare with ImageMagick
   compare -metric AE test/reference/screenshots/smb-title.png /tmp/smb-title.png /tmp/diff.png
   ```

   **Pass criteria**: `compare` returns 0 (identical) or difference count below threshold (e.g., <100 pixels for minor timing variations)

**Recommended visual test cases**:
| ROM | Frame | Tests |
|-----|-------|-------|
| smb.nes | 300 | Title screen, basic background rendering |
| smb.nes | 1500 | Gameplay, scrolling, sprites |
| zelda.nes | 500 | Title screen, more complex background |

---

### 3.3 APU Tests (Audio Correctness)

**Prerequisites**: CPU and basic PPU tests passing

#### 3.3.1 APU Register Behavior

```bash
# Length counter
racket main.rkt --rom test/roms/nes-test-roms/apu_test/1-len_ctr.nes \
    --headless --frames 3000 --test-addr 0x6000

# Length table
racket main.rkt --rom test/roms/nes-test-roms/apu_test/2-len_table.nes \
    --headless --frames 3000 --test-addr 0x6000

# IRQ flag
racket main.rkt --rom test/roms/nes-test-roms/apu_test/3-irq_flag.nes \
    --headless --frames 3000 --test-addr 0x6000

# Clock jitter
racket main.rkt --rom test/roms/nes-test-roms/apu_test/4-jitter.nes \
    --headless --frames 3000 --test-addr 0x6000

# Length timing
racket main.rkt --rom test/roms/nes-test-roms/apu_test/5-len_timing.nes \
    --headless --frames 3000 --test-addr 0x6000

# IRQ flag timing
racket main.rkt --rom test/roms/nes-test-roms/apu_test/6-irq_flag_timing.nes \
    --headless --frames 3000 --test-addr 0x6000

# DMC basics
racket main.rkt --rom test/roms/nes-test-roms/apu_test/7-dmc_basics.nes \
    --headless --frames 3000 --test-addr 0x6000

# DMC rates
racket main.rkt --rom test/roms/nes-test-roms/apu_test/8-dmc_rates.nes \
    --headless --frames 3000 --test-addr 0x6000
```

#### 3.3.2 APU Mixer Tests

From `nes-audio-tests`:
```bash
racket main.rkt --rom test/roms/nes-audio-tests/apu_mixer/square.nes \
    --headless --frames 2000 --test-addr 0x6000
```

#### 3.3.3 DMC DMA Timing

Critical for games that use DMC audio:
```bash
racket main.rkt --rom test/roms/nes-test-roms/dmc_dma_during_read4/dma_2007_read.nes \
    --headless --frames 2000 --test-addr 0x6000
```

---

### 3.4 Mapper Tests

**Prerequisites**: CPU, PPU basics passing

#### 3.4.1 MMC1

```bash
# Holy Diver Batman (auto-detects mapper, tests banking)
racket main.rkt --rom test/roms/nes-test-roms/holy_diver_batman/M1_P128K.nes \
    --headless --frames 2000 --test-addr 0x6000
```

**Visual test**: Zelda title screen renders correctly

#### 3.4.2 MMC3

```bash
# MMC3 test
racket main.rkt --rom test/roms/nes-test-roms/mmc3_test/1-clocking.nes \
    --headless --frames 3000 --test-addr 0x6000

racket main.rkt --rom test/roms/nes-test-roms/mmc3_test/2-details.nes \
    --headless --frames 3000 --test-addr 0x6000

racket main.rkt --rom test/roms/nes-test-roms/mmc3_test/3-A12_clocking.nes \
    --headless --frames 3000 --test-addr 0x6000

# IRQ tests
racket main.rkt --rom test/roms/nes-test-roms/mmc3_irq_tests/1.Clocking.nes \
    --headless --frames 3000 --test-addr 0x6000
```

#### 3.4.3 Other Mappers

For UxROM, CNROM: use Holy Diver Batman variants or visual testing with known games.
