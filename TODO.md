# TODO.md — NES Emulator Accuracy Improvements

This document tracks work needed to improve emulator accuracy, primarily driven by AccuracyCoin test results.

## Current Status

**AccuracyCoin Results (Mode A):** 83 passed, 46 failed, 5 draw
**AccuracyCoin Results (Mode B):** 69 passed, 61 failed, 5 draw

Mode B has 15 additional failures, primarily in illegal opcode page-crossing timing.

**Primary Test Command:**
```bash
PLTCOLLECTS="$PWD:" racket test/harness/accuracy-coin.rkt --failures
PLTCOLLECTS="$PWD:" racket test/harness/accuracy-coin.rkt --failures --tick  # Mode B
```

---

## Phase 1: Mode B Regressions (ACTIVE)

Fix the 15 additional failures that appear in Mode B but not Mode A.

### 1.1 Illegal Opcode Page-Crossing Timing
Mode B fails these but Mode A passes:
- [ ] $03 SLO INDIRECT'X
- [ ] $13 SLO INDIRECT'Y
- [ ] $1B SLO ABSOLUTE'Y
- [ ] $23 RLA INDIRECT'X
- [ ] $33 RLA INDIRECT'Y
- [ ] $3B RLA ABSOLUTE'Y
- [ ] $43 SRE INDIRECT'X
- [ ] $53 SRE INDIRECT'Y
- [ ] $5B SRE ABSOLUTE'Y
- [ ] $63 RRA INDIRECT'X
- [ ] $73 RRA INDIRECT'Y
- [ ] $7B RRA ABSOLUTE'Y
- [ ] $C3 DCP INDIRECT'X
- [ ] $D3 DCP INDIRECT'Y
- [ ] $DB DCP ABSOLUTE'Y
- [ ] $E3 ISC INDIRECT'X
- [ ] $F3 ISC INDIRECT'Y
- [ ] $FB ISC ABSOLUTE'Y

**Root Cause:** Likely dummy cycle timing on page-crossed indexed reads for read-modify-write illegal ops.

### 1.2 Instruction Timing
- [ ] INSTRUCTION TIMING test fails in Mode B only

### 1.3 Controller Clocking
- [ ] CONTROLLER CLOCKING passes in Mode B but fails in Mode A (error 5 → passes)
  - This is actually a Mode B improvement!

---

## Phase 2: CPU Timing Issues

### 2.1 Dummy Read/Write Cycles
Both modes fail:
- [ ] DUMMY READ CYCLES (error 1)
- [ ] DUMMY WRITE CYCLES (error 2)
- [ ] IMPLIED DUMMY READS (error 2)

### 2.2 Open Bus Behavior
- [ ] OPEN BUS (error 1) — CPU open bus emulation

### 2.3 Unofficial Instructions
- [ ] ALL NOP INSTRUCTIONS (error 2) — Unofficial NOP timing

### 2.4 JSR Edge Cases
- [ ] JSR EDGE CASES (error 2) — Stack timing edge cases

### 2.5 SHA/SHX/SHY/SHS Illegal Opcodes
These "unstable" opcodes have complex AND behavior:
- [ ] $93 SHA INDIRECT'Y (error 0)
- [ ] $9F SHA ABSOLUTE'Y (error 0)
- [ ] $9B SHS ABSOLUTE'Y (error 1)
- [ ] $9C SHY ABSOLUTE'X (error 1)
- [ ] $9E SHX ABSOLUTE'Y (error 1)

---

## Phase 3: Interrupt Handling

### 3.1 NMI/IRQ Overlap
- [ ] NMI OVERLAP BRK (error 2) — NMI during BRK instruction
- [ ] NMI OVERLAP IRQ (error 1) — NMI during IRQ handling

### 3.2 Interrupt Flag Latency
- [ ] INTERRUPT FLAG LATENCY (error 2) — I flag timing after SEI/CLI

---

## Phase 4: DMA Timing

### 4.1 OAM DMA Conflicts
- [ ] DMA + OPEN BUS (error 1) — Open bus during DMA
- [ ] DMA + $2007 READ (error 2) — DMA during VRAM read
- [ ] DMA + $2007 WRITE (error 1) — DMA during VRAM write
- [ ] DMA + $4015 READ (error 2) — DMA during APU status read
- [ ] DMA + $4016 READ (error 1) — DMA during controller read

### 4.2 DMC DMA
- [ ] DMC DMA BUS CONFLICTS (error 2) — DMC DMA bus behavior
- [ ] DMC DMA + OAM DMA (error 1) — DMC/OAM DMA interaction

### 4.3 DMA Abort
- [ ] EXPLICIT DMA ABORT (error 1)
- [ ] IMPLICIT DMA ABORT (error 1)

---

## Phase 5: APU Timing

### 5.1 Frame Counter
- [ ] FRAME COUNTER IRQ (error 6) — IRQ timing
- [ ] FRAME COUNTER 4-STEP (error 1) — 4-step mode timing
- [ ] FRAME COUNTER 5-STEP (error 1) — 5-step mode timing

### 5.2 DMC
- [ ] DELTA MODULATION CHANNEL (error 0) — DMC implementation

### 5.3 Register Timing
- [ ] APU REGISTER ACTIVATION (error 1) — Register enable timing

---

## Phase 6: Controller Timing

- [ ] CONTROLLER STROBING (error 3) — Strobe timing precision
- [ ] CONTROLLER CLOCKING (error 5 in Mode A, passes in Mode B)

---

## Phase 7: PPU Accuracy

### 7.1 Register Behavior
- [ ] PPU REGISTER OPEN BUS (error 4) — Open bus decay timing
- [ ] PALETTE RAM QUIRKS (error 5) — Palette mirroring/behavior

### 7.2 VBlank/NMI
- [ ] VBLANK BEGINNING (error 1) — VBlank set timing
- [ ] NMI TIMING (error 1) — NMI edge timing
- [ ] NMI SUPPRESSION (error 1) — Suppression window
- [ ] NMI DISABLED AT VBLANK (error 1) — NMI enable at VBlank edge

### 7.3 Rendering
- [ ] RENDERING FLAG BEHAVIOR (error 1) — BG/sprite enable timing
- [ ] ATTRIBUTES AS TILES (error 1) — Attribute table rendering
- [ ] STALE BG SHIFT REGISTERS (error 3) — BG shift register reload
- [ ] BG SERIAL IN (error 2) — BG pattern shift

### 7.4 Sprites
- [ ] ARBITRARY SPRITE ZERO (error 2) — Sprite 0 hit timing
- [ ] SPRITES ON SCANLINE 0 (error 2) — Scanline 0 sprite evaluation

### 7.5 OAM
- [ ] MISALIGNED OAM BEHAVIOR (error 1) — OAM access alignment
- [ ] ADDRESS $2004 BEHAVIOR (error 1) — OAMDATA read behavior
- [ ] OAM CORRUPTION (error 2) — OAM corruption during rendering
- [ ] INC $4014 (error 1) — OAM DMA page increment

---

## Completed Work

### Mode B Infrastructure ✅
- [x] Cycle-stepped CPU (`lib/6502/cycle-cpu.rkt`)
- [x] Master tick function (`nes-tick!`)
- [x] Frame execution (`nes-run-frame-tick!`)
- [x] DMA integration with cycle stepping
- [x] All ppu_vbl_nmi tests pass (1-10)
- [x] nestest 5003 steps pass
- [x] 205 unit tests pass

### AccuracyCoin Harness ✅
- [x] Automatic test execution
- [x] Screen parsing for results
- [x] Mode A/B support
- [x] PASS/FAIL/DRAW detection
- [x] Detailed failure reporting

---

## Priority Order

1. **Phase 1** — Mode B regressions (get Mode B to parity with Mode A)
2. **Phase 4** — DMA timing (affects many games)
3. **Phase 3** — Interrupt handling (affects game compatibility)
4. **Phase 6** — Controller timing (affects input responsiveness)
5. **Phase 7** — PPU accuracy (affects visual correctness)
6. **Phase 2** — CPU timing (edge cases)
7. **Phase 5** — APU timing (affects audio)

---

## References

- AccuracyCoin: https://github.com/100thCoin/AccuracyCoin
- nesdev wiki: https://www.nesdev.org/wiki/
- Visual 6502 for cycle-accurate verification
