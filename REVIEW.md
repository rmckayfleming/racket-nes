# Code Review Report

**Date:** December 24, 2025
**Reviewer:** Gemini CLI Agent

## Executive Summary

The `racket/nes` project is a well-structured NES emulator implementation. It demonstrates a clear separation of concerns, good use of Racket features (structs, modules, macros), and follows a logical development roadmap. The "Phase 1" goals (CPU, basic PPU, Mode A timing) are largely met with high code quality.

However, as the project moves towards more complex rendering and "Phase 3" (Playability), there are significant performance risks and a few architectural redundancies that should be addressed.

## Key Findings

### 1. The Memory Bus & Performance (`lib/bus.rkt`)
*   **Issue:** The generic bus implementation uses a list of handlers and `for/first` linear search for every read/write.
*   **Impact:** This is an O(N) dispatch on every memory access. Given the CPU ticks at 1.79MHz and the PPU at 5.37MHz, this linear search is the single largest bottleneck in the system.
*   **Recommendation:** Implement a dispatch table (vector of 65536 entries) for the CPU bus and PPU bus. Even a page-based dispatch (256-byte pages) would significantly improve performance.

### 2. PPU Timing & Sprite 0 Hit (`nes/ppu/render.rkt`, `nes/system.rkt`)
*   **Issue:** `check-sprite0-hit?` is called **every PPU cycle** during visible scanlines. Inside, it re-fetches and re-decodes tiles from the PPU bus.
*   **Impact:** This turns a simple "is this pixel opaque?" check into a heavy memory-access and bit-manipulation operation 5.3 million times per second.
*   **Recommendation:** 
    *   Pre-calculate Sprite 0's scanline range and X range.
    *   Only perform the opaque check when the PPU counters are within those bounds.
    *   Consider caching the decoded Sprite 0 pattern for the current frame.

### 3. Interrupt Handling Redundancy (`nes/system.rkt`, `lib/6502/cpu.rkt`)
*   **Observation:** `nes/system.rkt` maintains an `nmi-pending-box`, while `lib/6502/cpu.rkt` has its own `nmi-box`.
*   **Risk:** The PPU sets the system-level box, which `nes-step!` then transfers to the CPU-level box. This two-stage signaling is slightly fragile.
*   **Recommendation:** The PPU could directly call `cpu-trigger-nmi!` or the CPU could expose its `nmi-box` for direct modification by the system orchestration layer.

### 4. PPU Register Semantics (`nes/ppu/regs.rkt`)
*   **Strengths:** Excellent implementation of the `t`, `v`, `x`, `w` internal registers (scrolling/addressing latches). It correctly handles the complex side effects of $2000, $2002, $2005, and $2006.
*   **Minor Issue:** `ppu-read-data` ($2007) correctly handles the 1-byte read buffer, but ensure palette reads ($3F00+) don't accidentally update the buffer with palette data (they should update it with the "underlying" nametable data, which the current code appears to do).

### 5. Memory Map & Mappers (`nes/memory.rkt`, `nes/mappers/nrom.rkt`)
*   **Strengths:** The use of boxes for callbacks allows for clean late-binding of PPU and Mapper components to the memory bus.
*   **Mapper Design:** The `mapper` struct is well-defined. `nrom.rkt` correctly handles 16KB vs 32KB PRG ROM mirroring.
*   **Note:** `nrom.rkt` always allocates 8KB of PRG RAM. While harmless, a more memory-efficient approach would be to check `rom-prg-ram-size` from the header.

## Action Plan Recommendations

1.  **Immediate Performance Fix:** Refactor `lib/bus.rkt` to use a 64KB vector for dispatch.
2.  **Critical Optimization:** Optimize `check-sprite0-hit?` to use bounding-box short-circuiting.
3.  **Refactoring:** Unify the NMI signaling to use the `cpu-trigger-nmi!` interface directly from the PPU side-effect handlers.
4.  **Scaling:** Prepare for MMC1 and MMC3 by ensuring the `mapper` interface can handle dynamic mirroring changes efficiently (it currently does this via `get-mirroring` callbacks, which is good).

## Conclusion

The codebase is in excellent shape. It is readable, well-tested, and architecturally sound. Addressing the O(N) bus dispatch and the Sprite 0 hit check will provide the performance headroom needed for more advanced features.
