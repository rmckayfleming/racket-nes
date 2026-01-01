# TODO.md — Cycle-Accurate NES Refactor Plan

This list replaces the old test-ROM-driven checklist with a system-level plan
to reach full cycle accuracy (CPU/PPU/APU/DMA/mapper).

## Goal
- Full cycle accuracy across all subsystems with one authoritative tick path.

## Guiding Principles
- One master clock: all state changes happen in the tick path.
- No frame-based rendering for correctness; pixels are produced per dot.
- All bus activity updates open bus state on the exact cycle it occurs.
- Mappers observe real PPU address activity, not scanline shortcuts.

## Workstreams

### 1) Master Clock and Scheduler
- [ ] Make `nes-tick!` the only authoritative clock for CPU/PPU/APU/DMA.
- [ ] Document and enforce bus arbitration order per CPU cycle.
- [ ] Make `nes-step!` a thin loop over `nes-tick!` only.

### 2) CPU Cycle Engine Consolidation
- [ ] Use the cycle CPU (`cpu-tick!`) for all execution paths.
- [ ] Remove or reduce the instruction-level executor to a wrapper.
- [ ] Ensure opcode timing tables and illegal opcodes are consistent in one place.
- [ ] Model interrupt latency and overlap (BRK/NMI/IRQ) in the cycle engine.

### 3) PPU Cycle Pipeline
- [ ] Implement background fetch pipeline (nametable/attribute/pattern fetches).
- [ ] Implement background shift registers and fine X at dot accuracy.
- [ ] Implement sprite evaluation (secondary OAM) on the correct dots.
- [ ] Implement sprite fetches (dots 257-320) and sprite shift registers.
- [ ] Implement sprite 0 hit and overflow timing at the correct pixel/dot.
- [ ] Implement v/t register transfers and scroll increments per dot.
- [ ] Emit one pixel per dot into a PPU-owned framebuffer during `ppu-tick!`.
- [ ] Keep the existing `render-frame!` only as an optional debug view.

### 4) PPU Bus -> Mapper A12 Timing
- [ ] Add mapper callbacks for every PPU read/write to observe A12 changes.
- [ ] Implement MMC3 A12 edge filter timing (low-cycle counter).
- [ ] Remove scanline-tick IRQ shortcuts; use real A12 edges.
- [ ] Add 4-screen VRAM support when mapper provides it.

### 5) OAM DMA Engine (Per-Cycle)
- [ ] Replace immediate OAM copy with a per-cycle DMA state machine.
- [ ] Model the alignment cycle (odd CPU cycle -> +1) and 512 transfers.
- [ ] Update OAM as bytes transfer, not upfront.
- [ ] Stall CPU only while DMA is active; PPU/APU keep ticking.
- [ ] Update open bus with DMA reads at the correct cycles.

### 6) DMC DMA (Per-Fetch Steal)
- [ ] Replace fixed 4-cycle stall with DMA request/ack per DMC fetch.
- [ ] Implement exact alignment behavior for DMC steals.
- [ ] Model interaction/priority between DMC DMA and OAM DMA.
- [ ] Update open bus with fetched DMC byte on the correct cycle.

### 7) APU Timing Accuracy
- [ ] Implement exact frame counter cycles (4-step and 5-step modes).
- [ ] IRQ timing and inhibit behavior at correct boundaries.
- [ ] Channel clocking alignment to CPU cycles (pulse/noise half-rate).
- [ ] Finalize DAC/mixer step timing so audio is cycle-accurate.
- [ ] Ensure $4015/$4017 side effects follow cycle timing rules.

### 8) Open Bus and Register Side Effects
- [ ] Centralize open bus behavior for CPU and PPU access paths.
- [ ] Implement PPU register open bus decay and partial-bit reads.
- [ ] Ensure unmapped reads return the last latched bus value.

### 9) Presentation Layer
- [ ] Present the PPU framebuffer without re-rendering from VRAM each frame.
- [ ] Keep vsync pacing in frontend; avoid inserting emulator timing.

### 10) Validation and Regression
- [ ] Add focused cycle-accuracy tests for DMA, NMI, and PPU timing.
- [ ] Add MMC3 raster split tests that require correct A12 edges.
- [ ] Re-run nestest, blargg CPU tests, and PPU timing ROMs regularly.
- [ ] Keep a minimal trace/step harness for cycle debugging.

## Suggested Order
1) PPU cycle pipeline + framebuffer output
2) PPU bus A12 + MMC3 IRQ timing
3) OAM DMA per-cycle engine
4) DMC DMA per-fetch steals
5) CPU engine consolidation
6) APU frame counter accuracy
7) Open bus polish + register edge cases
8) Validation and regression suite
