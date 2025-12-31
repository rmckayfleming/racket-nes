# TODO.md — Mode B (Cycle-Accurate) Emulation

This document tracks the migration from Mode A (instruction-stepped) to Mode B (cycle-interleaved) emulation. Mode B is required to pass timing-sensitive tests like ppu_vbl_nmi tests 02, 05-10 and apu_test jitter tests.

## Background

**Mode A (Current):** CPU executes one full instruction, then PPU/APU catch up by the number of cycles consumed.

**Mode B (Target):** CPU, PPU, and APU advance one cycle at a time, interleaved. This allows mid-instruction register reads to see correct PPU state.

## Why Mode B?

Several test failures require cycle-level precision:
- `02-vbl_set_time.nes` — VBlank flag must be set at exact PPU cycle
- `05-nmi_timing.nes` through `08-nmi_off_timing.nes` — NMI edge detection timing
- `09-even_odd_frames.nes`, `10-even_odd_timing.nes` — Odd frame skip relative to rendering enable
- APU jitter tests — Frame IRQ timing precision

---

## Phase 1: CPU Cycle Decomposition ✅ COMPLETE

Break instruction execution into per-cycle steps. Each cycle performs one bus operation.

### 1.1 Instruction Microcode Table ✅
- [x] Define microcode format: state machine with per-cycle handlers
- [x] Each handler: address calculation, bus access, register updates
- [x] Implemented in `lib/6502/cycle-cpu.rkt`

### 1.2 Cycle-Stepped CPU Core ✅
- [x] Add `cpu-tick!` function that advances CPU by exactly 1 cycle
- [x] Track current instruction state via `instr-state` struct
- [x] Uses CPU's `cycle-box` and `instr-state-box` for state tracking
- [x] Handle interrupt injection between instructions (not mid-instruction)

### 1.3 Addressing Mode Cycle Patterns ✅
All addressing modes implemented with correct cycle counts:
- [x] Immediate (2 cycles): fetch opcode, fetch operand
- [x] Zero Page (3 cycles): fetch opcode, fetch addr, read/write
- [x] Zero Page,X/Y (4 cycles): fetch opcode, fetch addr, add index, read/write
- [x] Absolute (4 cycles): fetch opcode, fetch lo, fetch hi, read/write
- [x] Absolute,X/Y (4-5 cycles): +1 if page crossed on read
- [x] Indirect,X (6 cycles): fetch opcode, fetch ptr, add X, read lo, read hi, read/write
- [x] Indirect,Y (5-6 cycles): +1 if page crossed on read
- [x] Relative (2-4 cycles): branch taken +1, page crossed +1

### 1.4 Instruction-Specific Behaviors ✅
- [x] Read-modify-write: dummy write of old value before new value (6 cycles)
- [x] Stack operations: correct push/pull cycle counts
- [x] JMP indirect: page-wrap bug handled
- [x] BRK/RTI/interrupts: 7-cycle sequence

---

## Phase 2: Unified Tick Architecture ✅ COMPLETE

Create a master clock that drives all components in lockstep.

### 2.1 Master Clock ✅
- [x] Add `nes-tick!` function: advances entire system by 1 CPU cycle
- [x] Calls `cpu-tick!` once
- [x] Calls `ppu-tick!` three times (PPU runs 3x CPU rate)
- [x] Calls `apu-tick!` once (APU runs at CPU rate)
- [x] Returns instruction completion status for debugging

### 2.2 Dual Mode Support ✅
- [x] `nes-run-frame-tick!` for Mode B (cycle-interleaved) frame execution
- [x] `nes-step!` and `nes-run-frame!` kept for Mode A (instruction-stepped)
- [ ] Update debugger/trace to work with cycle granularity (future)

### 2.3 DMA Integration ✅
- [x] OAM DMA: CPU halted for 513-514 cycles, PPU/APU continue
- [x] DMC DMA: CPU halted for 4 cycles during sample fetch
- [x] DMA stall counter decremented in `nes-tick!`

---

## Phase 3: PPU Cycle Precision

PPU is already cycle-stepped but needs tighter integration.

### 3.1 Register Read Timing
- [ ] $2002 (PPUSTATUS): VBlank flag cleared on exact read cycle
- [ ] Reading during VBlank set cycle should see flag=0 (race condition)
- [ ] $2007 (PPUDATA): buffered read behavior per cycle

### 3.2 NMI Edge Detection
- [ ] NMI fires on LOW→HIGH transition of (nmi_occurred AND nmi_output)
- [ ] Track transition within each PPU cycle, not just instruction boundary
- [ ] Handle suppression: reading $2002 on VBlank set cycle clears nmi_occurred

### 3.3 Odd Frame Skip
- [ ] Skip happens at cycle 0 of pre-render scanline
- [ ] Only when rendering enabled AND odd frame
- [ ] "Rendering enabled" = PPU mask bits checked at cycle 0

### 3.4 Sprite 0 Hit Precision
- [ ] Hit detection happens at specific cycle within scanline
- [ ] Depends on sprite X position and first opaque pixel overlap
- [ ] Currently detected at cycle ranges; may need per-pixel precision

---

## Phase 4: APU Cycle Precision

APU is already cycle-stepped; verify integration is correct.

### 4.1 Frame Counter Timing
- [ ] Verify step boundaries match hardware (7457, 14913, 22371, 29829/37281)
- [ ] IRQ flag set timing relative to CPU reads
- [ ] 1-cycle delay before IRQ fires after flag set?

### 4.2 DMC DMA Timing
- [ ] Sample fetch stalls CPU for exactly 4 cycles
- [ ] Stall can occur on any CPU cycle, not just instruction boundary
- [ ] Verify stall cycle counting is correct

### 4.3 Length Counter / Envelope Timing
- [ ] Length counter halt checked on correct frame step
- [ ] Envelope divider clocked at quarter frame
- [ ] Linear counter (triangle) behavior

---

## Phase 5: Testing & Validation

### 5.1 Regression Testing
- [ ] All 16 CPU instruction tests still pass
- [ ] PPU tests that currently pass still pass
- [ ] APU len_table test still passes

### 5.2 New Test Coverage
- [ ] `02-vbl_set_time.nes` — PASS target
- [ ] `05-nmi_timing.nes` — PASS target
- [ ] `06-suppression.nes` — PASS target
- [ ] `07-nmi_on_timing.nes` — PASS target
- [ ] `08-nmi_off_timing.nes` — PASS target
- [ ] `09-even_odd_frames.nes` — PASS target
- [ ] `10-even_odd_timing.nes` — PASS target
- [ ] APU `4-jitter.nes` — improved

### 5.3 Performance Benchmarking
- [ ] Measure frames/second before and after Mode B
- [ ] Profile hot paths (expect `nes-tick!` to be critical)
- [ ] Consider fast-path for headless testing if too slow

---

## Phase 6: Optional Enhancements

### 6.1 Debugger Updates
- [ ] Step by cycle instead of instruction
- [ ] Show current instruction cycle number
- [ ] Breakpoints on PPU scanline/cycle

### 6.2 Hybrid Mode
- [ ] Fast mode: skip cycle-accurate PPU rendering
- [ ] Accurate mode: full cycle interleaving
- [ ] Per-frame or per-scanline mode switching for games that need it

---

## Implementation Notes

### CPU Microcode Example

```
LDA #imm (2 cycles):
  Cycle 1: Fetch opcode, decode
  Cycle 2: Fetch operand, load A, set N/Z

LDA abs,X (4-5 cycles):
  Cycle 1: Fetch opcode
  Cycle 2: Fetch addr lo
  Cycle 3: Fetch addr hi
  Cycle 4: Read from addr+X (if no page cross, load A)
  Cycle 5: Read from correct addr (if page crossed, load A)

STA abs (4 cycles):
  Cycle 1: Fetch opcode
  Cycle 2: Fetch addr lo
  Cycle 3: Fetch addr hi
  Cycle 4: Write A to addr

INC abs (6 cycles):
  Cycle 1: Fetch opcode
  Cycle 2: Fetch addr lo
  Cycle 3: Fetch addr hi
  Cycle 4: Read value
  Cycle 5: Write value (dummy)
  Cycle 6: Write value+1
```

### State Machine Approach

```racket
;; Possible states for cycle-stepped CPU
(struct cpu-instr-state
  (opcode          ; Current opcode being executed
   cycle           ; Which cycle of instruction (1-based)
   addr-lo         ; Low byte of address
   addr-hi         ; High byte of address
   data            ; Intermediate data
   effective-addr) ; Calculated effective address
  #:transparent)
```

### Key Files Modified

| File | Status | Changes |
|------|--------|---------|
| `lib/6502/cycle-cpu.rkt` | ✅ NEW | Cycle-stepped CPU with `cpu-tick!`, ~1600 lines |
| `lib/6502/cpu.rkt` | ✅ | Added `cycle-box`, `instr-state-box` fields |
| `nes/system.rkt` | ✅ | Added `nes-tick!`, `nes-run-frame-tick!` |
| `nes/ppu/ppu.rkt` | 🔲 | Verify register timing accuracy (Phase 3) |
| `nes/apu/apu.rkt` | 🔲 | Verify frame counter timing (Phase 4) |
| `main.rkt` | 🔲 | Update frame loop if needed (Phase 5) |

---

## References

- https://www.nesdev.org/wiki/CPU — CPU timing details
- https://www.nesdev.org/wiki/PPU_rendering — PPU cycle-by-cycle
- https://www.nesdev.org/wiki/APU_Frame_Counter — APU timing
- https://www.nesdev.org/wiki/PPU_registers — Register read/write timing
- Visual 6502 — Cycle-accurate behavior verification
