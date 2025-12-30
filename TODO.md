# TODO.md

Architectural issues and improvements for the NES emulator.

## High Priority

### Sprite 0 Hit is Frame-Level
**Location:** `nes/system.rkt:418-427`

Sprite 0 hit is checked during PPU tick after the full CPU instruction completes. Real hardware checks pixel-by-pixel during rendering.

**Fix:** Integrate sprite 0 hit detection into the renderer, checking at the exact pixel coordinates.

### PPU-CPU Synchronization is Instruction-Grained
**Location:** `nes/system.rkt:8-15, 252-335`

The "Mode A" scheduler ticks PPU/APU only after entire CPU instructions complete. This means:
- A 1-cycle NMI delay becomes a 2-7 cycle delay depending on instruction length
- Mid-instruction PPU state changes cannot be observed by CPU

**Fix:** Implement "Mode B" cycle-interleaved scheduler for timing-sensitive games. Keep Mode A as fast path.

## Medium Priority

### APU Frame Counter Timing
**Location:** `nes/apu/apu.rkt`

Updated frame counter timing to use correct CPU cycle values (7457, 14913, 22371, 29829 for 4-step mode). However, 6/8 APU tests still fail. Remaining issues:
- $4017 write delay (3-4 cycles before reset takes effect) not implemented
- Length counter timing may be off by a few cycles
- DMC sample fetch and playback timing needs work

Tests passing: 2-len_table.nes (length lookup table is correct)
Tests failing: Timing-sensitive tests that require cycle-exact precision

**Fix:** Implement $4017 write delay, audit cycle-by-cycle timing against blargg test documentation.

## Low Priority

### Bus Handler Linear Search
**Location:** `lib/bus.rkt:108-111`

Page table provides O(1) lookup for common case, but contested pages fall back to O(n) linear search through handlers.

Not a practical issue given small handler count, but could optimize if needed.

### Mapper Integration Unnecessary Lambda Wrapper
**Location:** `nes/system.rkt:113-114`

```racket
(nes-memory-set-cart-write! mem
  (λ (addr val)
    ((mapper-cpu-write mapper) addr val)))
```

The lambda wrapper is unnecessary - could pass `mapper-cpu-write` directly.

### PPU Register Dispatch is Ad-Hoc
**Location:** `nes/ppu/regs.rkt:48-76`

Case statement with hardcoded register numbers. Could use register descriptor table for extensibility, but current approach works fine.

## Test Status

Current test results from TESTING.md:

| Category | Pass | Total | Notes |
|----------|------|-------|-------|
| CPU | 16 | 16 | All official opcodes pass |
| PPU | 3 | 10 | VBlank/NMI timing tests need cycle-level precision |
| APU | 1 | 8 | Frame counter, channels broken |
| Mappers | 1 | 6 | MMC3 IRQ implemented, tests need re-run |

## Architecture Notes

### Timing Model

The emulator uses "Mode A" instruction-stepped timing:
1. CPU executes one instruction, reports cycles consumed
2. PPU advances by `cycles * 3` (PPU runs at 3x CPU clock)
3. APU advances by `cycles`

This is simpler but less accurate than cycle-interleaved "Mode B" timing.

### State Fragmentation

Mutable state is spread across CPU, PPU, APU, and System structs using boxes. This makes atomic updates and save states harder. Consider consolidating related state.

### Renderer/PPU Split

PPU timing (`ppu-tick!`) and rendering (`render-frame!`) are separate code paths. This means scroll register changes during rendering don't affect output until the next frame.
