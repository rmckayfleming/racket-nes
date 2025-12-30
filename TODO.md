# TODO.md

Architectural issues and improvements for the NES emulator.

## High Priority

### Open Bus Not Implemented
**Location:** `lib/6502/cpu.rkt:85`, `nes/ppu/regs.rkt:50`, `nes/memory.rkt:181`

- CPU has `openbus-box` but the value is never returned from reads
- PPU register reads that should return open bus return hardcoded `0`
- $4018-$401F returns `0` instead of open bus

**Fix:** Return `(unbox openbus-box)` for unmapped reads. Update PPU register reads to return open bus for write-only registers.

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

### Two PPU Tick Functions Diverge
**Location:** `nes/system.rkt:339-448` vs `nes/system.rkt:470-509`

`ppu-tick!` and `ppu-tick-fast!` have different behavior:
- Fast mode skips sprite 0 hit detection
- Fast mode skips scroll register copying (cycles 280-304)
- Fast mode skips scanline scroll capture

**Fix:** Extract shared logic into common function, or document that fast mode may diverge.

### Renderer Ignores Scroll Registers
**Location:** `nes/ppu/render.rkt`

The renderer doesn't use PPU's v/t/x scroll registers. `ppu-capture-scanline-scroll!` is called during PPU tick but the captured values aren't used by the renderer.

**Fix:** Update renderer to use captured scroll values for each scanline.

### Sprite Overflow Never Set
**Location:** `nes/system.rkt:377`

`ppu-sprite-overflow?` is cleared on pre-render scanline but never set. The buggy hardware behavior (false positives after 8 sprites) is not implemented.

**Fix:** Implement sprite overflow detection in sprite evaluation, including the hardware bug.

### APU Frame Counter Timing
**Location:** `nes/apu/apu.rkt`

Implementation exists but 7/8 APU tests fail. Likely issues:
- Off-by-one errors in cycle counting
- Frame IRQ timing wrong
- DMC stall integration buggy

**Fix:** Debug against blargg's APU tests, fix timing issues.

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
