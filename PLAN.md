# NES Emulator Project Plan (Racket + SDL3)

A Racket-based NES emulator built on our SDL3 bindings, designed for clarity, correctness, and reusability—with explicit timing contracts, correct latch/buffer behavior, and a debugging-first workflow.

---

## Goals

1. Accurate enough to play the NES library’s “greatest hits” reliably
2. Clean separation of concerns enabling reuse in future emulators
3. Leverage Racket macros for expressive, maintainable definitions (opcodes, memory maps, tracing)
4. Comprehensive, automated test coverage using community test ROMs
5. Debuggable by design: traceability, save-states, and introspection tooling

Non-goals (initially):

* Perfect NTSC/PAL cycle exactness from day 1 (we’ll scaffold for it and improve over phases)
* Exotic peripherals beyond standard controllers (Zapper, etc.) until later

---

## Key Hardware Facts (NTSC baseline)

Master clock relationships (this is the core scheduling truth):

* NTSC master clock: ~21.47727 MHz
* PPU clock: master / 4  → ~5.3693175 MHz
* CPU clock: master / 12 → ~1.7897725 MHz
* **Ratio:** **3 PPU cycles per 1 CPU cycle**

Components:

* CPU: Ricoh 2A03 (6502 variant; **no decimal mode**)
* PPU: Ricoh 2C02 (256×240 output; scanline/cycle timing matters)
* APU: 2 pulse, 1 triangle, 1 noise, 1 DMC
* RAM: 2KB internal @ $0000-$07FF mirrored to $1FFF
* Nametable VRAM: 2KB internal (mirroring controlled by cart/mapper; sometimes four-screen)
* Palette RAM: 32B @ $3F00-$3F1F (with quirks)
* OAM (sprite RAM): 256B internal to PPU (written via $2004 and DMA via $4014)

---

## System Architecture

### The NES Hardware (conceptual)

```
┌─────────────────────────────────────────────────────────────┐
│                        Cartridge                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │  PRG ROM/RAM│  │  CHR ROM/RAM│  │      Mapper         │  │
│  │ (code/data) │  │ (graphics)  │  │ (banks/mirroring/IRQ)│  │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘  │
└─────────┼────────────────┼────────────────────┼─────────────┘
          │                │                    │
          ▼                ▼                    │
    ┌───────────┐    ┌───────────┐              │
    │  CPU Bus  │    │  PPU Bus  │              │
    └─────┬─────┘    └─────┬─────┘              │
          │                │                    │
    ┌─────┴─────┐    ┌─────┴─────┐              │
    │           │    │           │              │
    ▼           ▼    ▼           ▼              │
┌───────┐  ┌───────┐ ┌───────┐ ┌────────┐       │
│ 2A03  │  │  RAM  │ │ 2C02  │ │ VRAM   │       │
│ (CPU) │  │ 2KB   │ │ (PPU) │ │ 2KB    │       │
└───┬───┘  └───────┘ └───┬───┘ └────────┘       │
    │                    │                      │
    │     ┌──────────────┘                      │
    │     │                                     │
    ▼     ▼                                     │
┌─────────────┐                                 │
│    APU      │◄────────────────────────────────┘
│ (in 2A03)   │
└─────────────┘
```

---

## Timing Model (explicit contract)

We will implement two timing modes:

### Mode A: Instruction-stepped (initial)

* Execute one CPU instruction.
* CPU reports how many cycles it consumed.
* Advance PPU by `cycles * 3`.
* Advance APU by `cycles` (or sub-steps as needed for frame counter timing).
* Apply DMA stalls by injecting extra CPU cycles (and corresponding PPU/APU catch-up).

Works for most titles; easiest to debug.

### Mode B: Cycle-interleaved (accuracy phase)

* Advance the system in CPU cycles (or half-cycles where relevant).
* PPU/APU tick alongside the CPU, enabling tight timing dependencies.

We will design the system so Mode B is a swap-in scheduler without rewriting components.

---

## Project Structure

```
nes-emulator/
├── PLAN.md
├── main.rkt
│
├── lib/
│   ├── 6502/
│   │   ├── cpu.rkt
│   │   ├── opcodes.rkt
│   │   ├── addressing.rkt
│   │   ├── disasm.rkt
│   │   └── microtiming.rkt      ; optional: shared helpers for RMW/penalties
│   ├── bus.rkt
│   ├── bits.rkt
│   └── serde.rkt                ; save-state serialization helpers
│
├── nes/
│   ├── system.rkt               ; scheduler + master clock
│   ├── memory.rkt               ; CPU memory map
│   ├── openbus.rkt              ; last-data-line model + helpers
│   ├── dma.rkt                  ; OAM DMA + (later) DMC DMA hooks
│   ├── ppu/
│   │   ├── ppu.rkt
│   │   ├── regs.rkt             ; latch/buffer semantics centralized
│   │   ├── render.rkt
│   │   ├── palette.rkt
│   │   └── timing.rkt           ; scanline/cycle constants, events
│   ├── apu/
│   │   ├── apu.rkt
│   │   ├── regs.rkt             ; register interface + side effects
│   │   ├── framecounter.rkt
│   │   ├── channels.rkt
│   │   └── mixer.rkt
│   ├── input/
│   │   ├── controller.rkt       ; shift registers $4016/$4017 behavior
│   │   └── mapping.rkt          ; frontend mapping -> controller bits
│   └── mappers/
│       ├── mapper.rkt
│       ├── nrom.rkt
│       ├── mmc1.rkt
│       ├── uxrom.rkt
│       ├── cnrom.rkt
│       └── mmc3.rkt
│
├── cart/
│   ├── ines.rkt
│   └── saves.rkt                ; battery-backed PRG RAM persistence
│
├── frontend/
│   ├── sdl.rkt
│   ├── video.rkt
│   ├── audio.rkt
│   ├── input.rkt
│   └── pacing.rkt               ; frame pacing + drift correction
│
├── debug/
│   ├── debugger.rkt
│   ├── trace.rkt
│   ├── viewer.rkt
│   ├── savestate.rkt            ; debug-friendly save/load state
│   └── compare.rkt              ; compare traces vs reference (Mesen/FCEUX)
│
└── test/
    ├── roms/                    ; gitignored
    ├── cpu-test.rkt
    ├── ppu-test.rkt
    ├── apu-test.rkt
    ├── mapper-test.rkt
    ├── reference/
    └── harness/
        ├── run-rom.rkt
        ├── screenshot.rkt
        └── trace.rkt
```

---

## Core Design: Bus + Side Effects + Open Bus

### CPU Bus must support:

* read/write handlers by address range
* mirroring rules
* handler side effects (PPU register reads, controller shift, etc.)
* “open bus” behavior: unmapped reads often return **last value on the data lines**

We’ll model an explicit “data bus last value” and update it on reads/writes where appropriate.

---

## Cartridge Support (initial scope)

### ROM formats

* iNES 1.0 (required)
* NES 2.0 (parse fields; implement only what we need initially)

### Memory types

* PRG ROM (required)
* CHR ROM or **CHR RAM** (must support both)
* PRG RAM (optional; common)
* **Battery-backed PRG RAM** (persist to disk; needed for Zelda, etc.)

### Mirroring

* horizontal/vertical/four-screen
* mapper-controlled mirroring (MMC1/MMC3 later)

---

## Implementation Phases

### Phase 1: CPU + ROM + Deterministic Core (no graphics required)

Focus: correctness, traceability, test harness.

Deliverables:

* iNES parser (PRG/CHR, mirroring, PRG RAM/CHR RAM flags)
* CPU bus + mirroring + open bus model (basic)
* 6502 core: all official opcodes + addressing modes
* cycle timing essentials:

  * page-cross penalties where applicable
  * branch taken/not-taken + page-cross extra
  * correct interrupt sequencing (NMI/IRQ/BRK behaviors)
  * read-modify-write instruction bus behavior (timing model)
* controller registers stubbed (reads return deterministic values)
* APU register map stubbed (writes accepted; no sound yet)
* tracing + nestest automation harness

Acceptance criteria:

* `nestest.nes` runs in automation mode with matching log output
* `instr_test-v5/` (or equivalent) passes for official opcodes
* unit tests for bus mirroring and open-bus basics

Milestone:

* `nestest` matches reference exactly.

---

### Phase 2: PPU Registers + DMA + “See Something” (minimal video, correct semantics)

Focus: PPU register semantics (latches/buffers), OAM DMA, and a stable video pipeline.

Key PPU semantics (must be correct early):

* $2002 PPUSTATUS: vblank clear-on-read, w-toggle reset
* $2005/$2006 write toggle behavior (w latch), t/v/x registers model
* $2007 buffered reads (except palette), address increment (1/32)
* palette RAM quirks (including $3F10 mirroring behavior)
* OAMDATA $2004 auto-increment behavior (as implemented by real PPU)

DMA:

* $4014 OAM DMA:

  * copies 256 bytes from CPU page to OAM
  * stalls CPU for 513 or 514 cycles depending on alignment
  * interacts with open bus / last value as applicable

Video:

* SDL texture pipeline
* stable framebuffer format (RGBA u8vector)
* deterministic palette selection (document which palette we use)

Acceptance criteria:

* PPU register tests (e.g., `ppu_vbl_nmi` style ROMs) show expected behavior
* OAM DMA present: sprite-based games no longer show “missing sprites” due to DMA absence
* render: solid test pattern + at least one known title screen renders stably

Milestone:

* Static title screens render correctly with correct palette and stable VRAM access behavior.

---

### Phase 3: Input + Sprites + Playability (Donkey Kong tier)

Focus: sprites and controller correctness.

Input:

* $4016/$4017 controller shift registers:

  * strobe behavior
  * serial reads over 8 buttons
  * post-8 reads behavior (document/approx; refine later)

Sprites:

* OAM evaluation (initial approximation ok if stable)
* 8-sprites-per-scanline limit (flicker behavior)
* sprite priority vs background
* sprite 0 hit behavior (enough for common split effects)

Acceptance criteria:

* menu navigation works in multiple games
* characters visible and stable
* sprite 0 hit tests pass or are close with known deviations documented

Milestone:

* Donkey Kong is fully playable.

---

### Phase 4: Scrolling + Nametables (Mario tier)

Focus: correct scrolling model and mirroring.

* PPUSCROLL + PPUADDR interaction (t/v/x)
* fine scrolling (pixel-level) and coarse scrolling
* nametable mirroring modes honored from ROM header and mapper
* mid-frame scroll changes (split scrolling) in Mode A timing as far as possible

Acceptance criteria:

* Super Mario Bros World 1 scrolls smoothly
* status bar remains stable where expected

Milestone:

* Super Mario Bros is playable through World 1 (NTSC baseline).

---

### Phase 5: Mapper Expansion (real compatibility leap)

Add mappers in a game-driven order, with clean interfaces.

Required behaviors to include in mapper interface:

* PRG banking
* CHR banking
* mirroring control (where relevant)
* IRQ hooks (MMC3 scanline counter)
* PRG RAM enable/disable and persistence

Mappers:

* NROM (0)
* MMC1 (1)
* UxROM (2)
* CNROM (3)
* MMC3 (4)

Acceptance criteria:

* Zelda (MMC1) boots + saves
* Mega Man (UxROM) runs
* Gradius (CNROM) runs
* SMB3 (MMC3) runs with stable scanline effects (or documented limitations pre-Phase 7)

Milestone:

* Broad “greatest hits” compatibility across common mappers.

---

### Phase 6: APU Semantics First, Sound Second

Split APU work intentionally:

#### 6A: Register semantics + timing/IRQ correctness (even if silent)

* frame counter timing + mode
* frame IRQ behavior
* DMC register behavior + DMA scheduling hooks (even before full sample playback)
* ensure games that rely on APU timing don’t break

Acceptance criteria:

* APU timing test ROMs pass for register semantics/IRQs where applicable
* no hangs or logic bugs caused by missing APU side effects

#### 6B: Actual audio generation

* pulse (duty, envelope, sweep)
* triangle (linear counter)
* noise (LFSR)
* DMC playback (delta modulation)
* nonlinear mixing + optional filters (document what we do)

Output:

* resampling to device sample rate
* ring buffer or SDL queue with drift correction vs video pacing

Milestone:

* games sound recognizably correct without drift/crackle.

---

### Phase 7: Accuracy Mode (Cycle Interleaving + Edge Cases)

Bring up Mode B scheduler and fix tricky timing dependencies.

* cycle-interleaved CPU/PPU/APU
* PPU scanline/cycle timing correctness
* sprite overflow flag behavior (as accurate as feasible)
* open bus refinements
* power-up state options (configurable presets)
* unofficial opcodes (add as a separate table; keep official core clean)

Acceptance criteria:

* blargg timing tests (CPU + PPU sets) pass to documented thresholds
* known tricky titles behave correctly (raster effects, IRQ splits, etc.)

Milestone:

* high compatibility with “tricky” games and test ROMs.

---

## DSL Design

### Opcode Definition Macro

Goals:

* concise opcode definitions
* generate decode logic + disassembly formatting
* support conditional cycle increments cleanly (page-cross, branch taken)
* represent RMW and bus quirks without hiding them

Sketch:

```racket
(define-opcode LDA
  [(immediate #xA9
     #:bytes 2
     #:cycles 2
     #:disasm "LDA #$%02X"
     (set-A! (fetch-byte))
     (update-NZ! A))]

  [(absolute-x #xBD
     #:bytes 3
     #:cycles 4
     #:cycles+ (if (page-crossed?) 1 0)
     #:disasm "LDA $%04X,X"
     (set-A! (read-byte (addr-abs-x)))
     (update-NZ! A))])
```

### Memory Map Macro

Goals:

* declarative, readable map
* generate fast dispatch
* generate a human-readable map (debug print)
* integrate mirroring + open-bus defaults

```racket
(define-memory-map cpu-bus
  [$0000 $07FF internal-ram (mirror 3)]
  [$2000 $2007 ppu-registers (mirror 1024)]
  [$4000 $4017 apu-io]
  [$4014 $4014 oam-dma]          ; explicit: side-effect write
  [$4016 $4017 controllers]
  [$4020 $FFFF cartridge])
```

---

## Save States (debugging-first)

We will implement save-states early (Phase 2/3) for fast iteration:

* serialize CPU registers + internal RAM
* serialize PPU state (including latch/toggle/buffers, OAM, VRAM/palette)
* serialize mapper state (bank regs, IRQ counters, mirroring)
* serialize APU state (regs/counters) even if audio is incomplete

Save-states are primarily a development tool; later we can expose them in UI.

---

## Testing Strategy

### Test ROM Library (suggested baseline)

CPU:

* `nestest.nes`
* `instr_test-v5/` (or equivalent)
* `cpu_timing_test6.nes` (later)

PPU:

* vblank/NMI tests (e.g., `ppu_vbl_nmi`)
* scrolling tests (e.g., `scrolltest`)
* sprite hit tests (`sprite_hit_tests`)

APU:

* blargg APU tests or equivalent suites (phase 6A/6B)

Mappers:

* targeted mapper tests for MMC1/MMC3 (plus game-based validation)

### Automated Tests

Trace comparison:

```racket
(define (run-nestest-comparison)
  (define nes (make-nes (load-rom "test/roms/nestest.nes")))
  (set-pc! nes #xC000)
  (for ([expected (in-lines (open-input-file "test/reference/nestest.log"))])
    (define actual (trace-line nes))
    (check-equal? actual expected)
    (step! nes)))
```

Screenshot comparison (with palette determinism):

* Document which palette is used for tests (fixed palette file in repo)
* Compare generated PNG bytes (or compare hashes after normalization)

```racket
(define (check-screenshot rom reference #:frames [n 60])
  (define nes (make-nes (load-rom rom)))
  (for ([_ (in-range n)]) (run-frame! nes))
  (check-equal? (framebuffer->png nes #:palette 'test-fixed)
                (file->bytes reference)))
```

---

## Reusable Components

### `lib/6502/` — 6502 Core

Usable for: Apple II, C64, Atari, BBC Micro (with appropriate bus)

```racket
(define cpu (make-6502 bus))
(step! cpu)           ; one instruction (Mode A)
(tick! cpu n)         ; optional: N cycles (Mode B support)
(reset! cpu)
(irq! cpu)
(nmi! cpu)
(cpu-state cpu)       ; registers + cycles
```

### `lib/bus.rkt` — Memory Bus

* handler dispatch
* mirroring
* side-effect-aware reads/writes
* open bus integration

### `frontend/` — SDL3 Frontend

* video: texture upload + scaling
* input: SDL events -> controller mapping
* audio: resampling + buffering + drift correction

### `debug/`

* tracing
* breakpoints/watchpoints
* save-state load/save
* visualization hooks (PPU viewer, nametables, pattern tables)

---

## Known Challenges (explicit targets)

### PPU/CPU synchronization

Mode A first (instruction-stepped), Mode B later (cycle-interleaved).

### Sprite evaluation timing

Start stable + reasonably correct, then refine under Mode B.

### Audio synchronization

Video-driven first, but with drift correction + resampling:

* avoid crackle
* avoid long-term pitch drift

### Mapper complexity

Treat each mapper as a self-contained module with:

* bank switching
* mirroring
* IRQ hooks (if any)
* PRG RAM behavior and persistence

---

## Development Practices

### Commit Strategy

* small commits, one behavior change per commit
* tag each phase milestone
* CI runs fast unit tests + selected ROM harnesses (without bundling ROMs)

### Documentation

* each module begins with “hardware model” notes + edge cases
* reference nesdev wiki in comments
* macros generate docs/tables (opcode list, memory map, etc.)

### Debugging Workflow

1. Reproduce (ROM + save-state at failure if possible)
2. Enable trace / compare against known-good (Mesen/FCEUX)
3. Find first divergence
4. Add targeted test
5. Fix
6. Verify on both test ROM and real game

---

## Resources

* NesDev Wiki — hardware reference: [https://www.nesdev.org/wiki/](https://www.nesdev.org/wiki/)
* nestest reference log: [https://www.qmtpro.com/~nes/misc/nestest.txt](https://www.qmtpro.com/~nes/misc/nestest.txt)
* NES test ROM collections (various): [https://github.com/christopherpow/nes-test-roms](https://github.com/christopherpow/nes-test-roms)
* Mesen2 (reference emulator): [https://github.com/SourMesen/Mesen2](https://github.com/SourMesen/Mesen2)
