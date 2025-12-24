# TODO.md — NES Emulator (Racket + SDL3)

This is a *commit-friendly* breakdown of PLAN.md into small, shippable steps. Each item should ideally:

* change one behavior or add one new capability
* include a test (unit test, trace check, screenshot, or test ROM harness)
* leave the emulator runnable

Legend:

* [ ] TODO
* [x] Done
* (T) add/extend automated test
* (D) add debug tooling / trace hooks

---

## 0. Repo + Build + Harness (Day 0)

* [x] Add `raco`/`racket` entrypoint (`main.rkt`) that:
  * loads a ROM
  * constructs `nes/system`
  * runs for N steps/frames
  * supports CLI flags: `--rom`, `--headless`, `--steps`, `--frames`, `--trace`, `--screenshot-out`
* [x] Create `test/harness/run-rom.rkt` (headless runner)
* [x] Create `test/harness/trace.rkt` (writes trace lines)
* [x] Create `test/harness/screenshot.rkt` (renders N frames → PNG)
* [x] Set up `rackunit` test runner target (single `raco test` entry)
* [x] Add `test/roms/.gitignore` and a README telling how to download ROMs legally + test ROMs
* [x] Add CI skeleton that runs unit tests and any ROM harnesses that don't require ROM blobs

---

## 1. Shared Utilities

### 1.1 `lib/bits.rkt`

* [x] Implement u8/u16 helpers: `u8`, `u16`, `lo`, `hi`, `merge16`, `wrap8`, `wrap16`
* [x] Implement bit ops: `bit?`, `set-bit`, `clear-bit`, `update-bit`, `mask`, `extract`
* [x] (T) Unit tests for wrap and bit ops

### 1.2 `lib/bus.rkt` (generic bus)

* [x] Define bus struct with ordered handlers: `(start end read write mirror?)`
* [x] Implement `bus-add-handler!` and `bus-finalize` (optional precompute)
* [x] Implement `bus-read`, `bus-write` with mirroring support
* [x] Add a "default read" handler for unmapped addresses
* [x] (T) Unit tests: overlapping ranges precedence, mirroring, boundary correctness

### 1.3 `nes/openbus.rkt`

* [x] Add "last data bus value" state to the NES system (or bus)
* [x] Add helpers:

  * `openbus-read` (returns last)
  * `openbus-update!` (on reads/writes)
* [x] Decide convention: which reads/writes update last value (document in code)
* [x] (T) Unit test basic openbus behavior in isolation

### 1.4 `lib/serde.rkt` (save-state primitives)

* [x] Define a stable serialization format (e.g., tagged vectors / bytes)
* [x] Implement helpers for u8vector/u16 packing
* [x] Provide `serde-version` and forward-compat note
* [x] (T) Round-trip tests on synthetic state blobs

---

## 2. Cartridge Parsing + Persistence

### 2.1 iNES/NES2 parsing (`cart/ines.rkt`)

* [x] Parse iNES header (magic, PRG/CHR sizes, flags)
* [x] Parse mirroring + four-screen + battery flags
* [x] Detect CHR RAM vs CHR ROM
* [x] Parse PRG RAM size (best-effort for iNES, more correct for NES2)
* [x] Validate file size vs declared sizes with helpful error messages
* [x] (T) Parse 10+ known ROM headers (header-only tests using small fixtures)

### 2.2 Save RAM (`cart/saves.rkt`)

* [x] Define save path scheme (e.g., `~/.local/share/...` or next to ROM)
* [x] Load/save PRG RAM if battery flag set
* [x] (T) Unit test: write PRG RAM → persist → reload

---

## 3. CPU Core (6502 / 2A03)

### 3.1 CPU state + interface (`lib/6502/cpu.rkt`)

* [x] Define CPU registers, flags, cycle counter, interrupt pending flags
* [x] Implement reset vector fetch + reset behavior
* [x] Implement stack ops helpers (`push8`, `pull8`, `push16`, `pull16`)
* [x] Implement flag helpers: `setNZ`, `setC`, etc.
* [x] Implement bus access wrappers that update openbus (integration point)
* [x] (T) Micro tests for stack/flags and reset vector

### 3.2 Addressing modes (`lib/6502/addressing.rkt`)

* [x] Implement all official addressing modes (13) returning:
  * effective address
  * page-crossed? boolean (for cycle penalties)
  * and/or fetched operand (immediate)
* [x] Implement indexed indirect / indirect indexed correctly (wrap rules)
* [x] Implement JMP (indirect) page-boundary bug
* [x] (T) Unit tests for each addressing mode with known vectors

### 3.3 Opcode table DSL (`lib/6502/opcodes.rkt`)

* [x] Implement `define-opcode` macro that can attach:
  * opcode byte
  * bytes length
  * base cycles
  * optional conditional cycles `#:cycles+`
  * disasm format
  * executor body
* [x] Generate decode table and disasm table from macro expansions
* [x] Provide `decode` function mapping opcode → executor
* [x] (T) Smoke test: table contains all expected opcodes, no duplicates

### 3.4 Implement official instruction set

Target: *all official opcodes*, with correct flags.

* [x] ADC/SBC (binary mode only, no decimal)
* [x] AND/ORA/EOR
* [x] ASL/LSR/ROL/ROR (incl RMW)
* [x] Branches (BPL/BMI/BVC/BVS/BCC/BCS/BNE/BEQ)
* [x] BIT
* [x] CMP/CPX/CPY
* [x] DEC/INC (incl RMW)
* [x] JMP/JSR/RTS/RTI
* [x] LDA/LDX/LDY
* [x] STA/STX/STY
* [x] PHA/PLA/PHP/PLP
* [x] TAX/TAY/TSX/TXA/TXS/TYA
* [x] CLC/SEC/CLI/SEI/CLV/CLD/SED (SED should set D flag but D has no effect)
* [x] NOP
* [x] BRK interrupt semantics (push PC+2, status with B set in pushed copy)

### 3.5 Cycle timing correctness (Phase 1 critical)

* [x] Add page-cross penalties for relevant ops (loads, compares, etc.)
* [x] Branch timing:
  * not taken: +0
  * taken: +1
  * taken + page cross: +2 total
* [x] RMW bus behavior (at least timing-correct at instruction granularity)
* [x] NMI/IRQ sampling + sequencing (document model)

### 3.6 Disassembler (`lib/6502/disasm.rkt`)

* [x] Use opcode table metadata to format lines
* [x] Provide `trace-line` matching nestest-style formatting
* [x] (T) Golden tests for a few known instructions

### 3.7 `nestest` harness (Phase 1 milestone)

* [x] Implement headless run that:
  * loads `nestest.nes`
  * sets PC to $C000
  * steps and compares trace line by line
* [x] Store reference log in `test/reference/` (not ROM)
* [x] (T) `test/harness/nestest.rkt` runs and fails at first mismatch with diff context
* [x] All 5003 official opcode tests pass

---

## 4. NES CPU Memory Map + Stubs (enough to run CPU tests)

### 4.1 Core memory map (`nes/memory.rkt`)

* [x] Internal RAM $0000-$07FF + mirrors to $1FFF
* [x] PPU regs $2000-$2007 + mirrors to $3FFF (stub read/write initially)
* [x] APU/IO $4000-$4017 (accept writes; stub reads)
* [x] Test range $4018-$401F (optional; keep as open bus or configurable)
* [x] Cart space $4020-$FFFF (mapper hooks)
* [x] (T) Unit tests for mirroring correctness and handler dispatch

### 4.2 Mapper interface + NROM (`nes/mappers/`)

* [x] Mapper interface (`mapper.rkt`) with CPU/PPU read/write, mirroring, IRQ, serialization
* [x] PRG ROM mapping (16KB mirrored or 32KB)
* [x] CHR ROM/CHR RAM mapping for PPU bus
* [x] PRG RAM mapping ($6000-$7FFF)
* [x] (T) Unit tests for PRG bank mirroring behavior

---

## 5. System Scheduler (Mode A first)

### 5.1 `nes/system.rkt`

* [x] Define `nes` struct holding CPU/mapper/memory/counters
* [x] Implement `step!`:
  * run 1 CPU instruction
  * get CPU cycles
  * (TODO) tick PPU by cycles*3
  * (TODO) tick APU by cycles
  * (TODO) apply pending DMA stalls (Phase 7)
* [x] Implement `run-frame!` placeholder (later becomes PPU-driven)
* [x] (D) Add trace toggles
* [x] (T) Unit tests for system creation, stepping, reset

---

## 6. PPU Foundations (register semantics first)

### 6.1 PPU state (`nes/ppu/ppu.rkt` + `nes/ppu/timing.rkt`)

* [x] Define PPU timing constants (scanlines, cycles, vblank start/end)
* [x] Define PPU state:
  * v, t, x, w (scroll/address latches)
  * status bits, mask, ctrl
  * OAM (256B), secondary OAM
  * palette RAM (32B)
  * nametable VRAM (2KB)
  * read buffer for $2007
* [x] Implement `ppu-tick!` advancing by 1 PPU cycle (even if Mode A batches)

### 6.2 PPU registers semantics (`nes/ppu/regs.rkt`)

Implement correct side effects early:

* [x] $2000 PPUCTRL: NMI enable, increment, pattern table selects
* [x] $2001 PPUMASK (store bits; rendering effects later)
* [x] $2002 PPUSTATUS:
  * vblank flag clear-on-read
  * resets w toggle
* [x] $2003 OAMADDR
* [x] $2004 OAMDATA read/write + auto-inc
* [x] $2005 PPUSCROLL: w toggle, sets x and t
* [x] $2006 PPUADDR: w toggle, sets t and v
* [x] $2007 PPUDATA:
  * buffered reads for non-palette
  * no buffering for palette reads
  * increment v by 1/32
* [x] Palette quirks:
  * $3F10/$3F14/$3F18/$3F1C mirror to $3F00/$3F04/$3F08/$3F0C

### 6.3 PPU bus (separate from CPU bus)

* [x] Define PPU bus mapping:
  * pattern table $0000-$1FFF from CHR ROM/RAM (mapper)
  * nametables $2000-$2FFF internal VRAM with mirroring
  * palette $3F00-$3F1F with mirrors
* [x] (T) Unit tests for palette mirroring and nametable mirroring modes

---

## 7. OAM DMA (this unblocks many games)

### 7.1 DMA implementation (`nes/dma.rkt`)

* [x] Implement $4014 write handler:
  * source page = value << 8
  * copy 256 bytes CPU memory → PPU OAM
  * apply CPU stall cycles: 513 or 514 depending on CPU cycle parity
* [x] Integrate DMA stall into scheduler:
  * easiest: after write, set `dma-stall-cycles` counter
  * each `step!` consumes stall cycles appropriately (no instruction fetch)
* [x] (T) Unit test:
  * copy correctness
  * stall cycle count parity behavior

---

## 8. Minimal Video Output (SDL3)

### 8.1 Frontend video pipeline (`frontend/video.rkt`)

* [ ] Create SDL window + texture
* [ ] Upload RGBA framebuffer
* [ ] Integer scaling support
* [ ] (T) Smoke test: render solid color pattern

### 8.2 Deterministic palette (`nes/ppu/palette.rkt`)

* [ ] Choose and document a fixed 64-color palette for tests
* [ ] Implement palette lookup function returning RGBA

### 8.3 Background rendering (incremental)

Start simple: render a single nametable without scrolling.

* [ ] Implement pattern table fetch from CHR
* [ ] Implement nametable + attribute table interpretation
* [ ] Render background into framebuffer (256×240)
* [ ] (T) Screenshot test for a known title screen (once stable)

---

## 9. Controllers + Input

### 9.1 Controller shift register (`nes/input/controller.rkt`)

* [ ] Implement $4016 strobe behavior
* [ ] Implement serial reads for 8 buttons
* [ ] Decide/document post-8 reads behavior (approx acceptable initially)
* [ ] (T) Unit test: known read sequences given button states

### 9.2 SDL input mapping (`frontend/input.rkt` + `nes/input/mapping.rkt`)

* [ ] Map keyboard/gamepad to NES buttons
* [ ] Poll/update controller state once per frame (or per event)

---

## 10. Sprites (Playability)

### 10.1 Sprite rendering basics

* [ ] Implement sprite fetch from pattern tables
* [ ] Render sprites over background with priority bits
* [ ] Implement sprite transparency
* [ ] Implement sprite 0 hit detection (good-enough first)
* [ ] Implement 8-sprites-per-scanline limit (approx first)

### 10.2 Tests

* [ ] Add `sprite_hit_tests` harness runner + basic pass criteria
* [ ] Add screenshot-based regression tests for a sprite-heavy scene

---

## 11. Scrolling (Mario tier)

### 11.1 Scroll correctness (t/v/x/w)

* [ ] Implement coarse X/Y and fine X/Y scroll behavior
* [ ] Implement PPUSCROLL/PPUADDR interaction fully
* [ ] Implement nametable switching during scroll

### 11.2 Split scrolling (status bars)

* [ ] Support mid-frame changes to scroll regs (within Mode A limits)
* [ ] Add at least one split-scroll validation ROM/screenshot

---

## 12. Mapper Expansion

### 12.1 Common mapper interface (`nes/mappers/mapper.rkt`)

* [ ] Define clear interface:
  * CPU read/write
  * PPU read/write
  * mirroring control
  * optional IRQ hooks
  * serialize/deserialize for save-states

### 12.2 Implement mappers

* [ ] MMC1
  * [x] shift register writes
  * [ ] PRG bank modes
  * [ ] CHR bank modes
  * [ ] mirroring control
  * [ ] PRG RAM enable
  * [ ] (T) Zelda boots + saves
* [ ] UxROM
  * [ ] fixed/variable PRG bank
  * [ ] (T) Mega Man runs
* [ ] CNROM
  * [ ] CHR bank switching
  * [ ] (T) Gradius runs
* [ ] MMC3
  * [ ] PRG/CHR bank regs
  * [ ] scanline counter + IRQ
  * [ ] mirroring control
  * [ ] (T) MMC3 test ROMs + SMB3 basic correctness

---

## 13. APU: Semantics First (silent-but-correct)

### 13.1 Register map (`nes/apu/regs.rkt`)

* [ ] Store all APU regs with correct write side effects
* [ ] Status register reads, channel enables
* [ ] Frame counter config

### 13.2 Frame counter + IRQ (`nes/apu/framecounter.rkt`)

* [ ] Implement sequencing for 4-step/5-step
* [ ] Frame IRQ behavior
* [ ] (T) APU timing/IRQ test ROM harness (pass where applicable)

### 13.3 DMC DMA hooks (logic before sound)

* [ ] Implement DMC address/length regs
* [ ] Schedule memory reads and CPU cycle stealing hooks (even if output muted)
* [ ] (T) DMC timing sanity tests (as available)

---

## 14. APU: Sound Generation + Output

### 14.1 Channels (`nes/apu/channels.rkt`)

* [ ] Pulse: duty/envelope/sweep
* [ ] Triangle: linear counter
* [ ] Noise: LFSR
* [ ] DMC: delta modulation output

### 14.2 Mixing (`nes/apu/mixer.rkt`)

* [ ] Implement NES mixing formula (document)
* [ ] Optional filters (document)

### 14.3 SDL audio (`frontend/audio.rkt`)

* [ ] Choose device sample rate
* [ ] Implement resampling from APU tick rate to device
* [ ] Implement buffering (ring buffer) + drift correction vs video pacing
* [ ] (T) Audio smoke test: generate tone/known pattern without crackle

---

## 15. Debug Tooling (make fixing bugs fast)

### 15.1 Trace + compare (`debug/trace.rkt` + `debug/compare.rkt`)

* [ ] Toggleable instruction trace (nestest format)
* [ ] Compare against known-good traces (Mesen/FCEUX) with first-divergence report

### 15.2 Save states (`debug/savestate.rkt`)

* [ ] Save/load from file
* [ ] Integrate with debugger hotkeys (frontend)
* [ ] (T) Round-trip save-state for a running ROM (hash key regions)

### 15.3 Viewers (`debug/viewer.rkt`)

* [ ] Pattern table viewer
* [ ] Nametable viewer
* [ ] Palette viewer
* [ ] OAM viewer

---

## 16. Accuracy Mode (Cycle Interleaving)

### 16.1 Scheduler Mode B (`nes/system.rkt`)

* [ ] Add `tick-cpu-cycle!` primitive
* [ ] Implement cycle-level interleaving CPU/PPU/APU
* [ ] Ensure DMA stalls work in Mode B

### 16.2 Tight timing fixes

* [ ] Sprite 0 hit timing refinements
* [ ] MMC3 IRQ timing refinements
* [ ] PPU scanline/cycle event correctness
* [ ] Open bus refinements (as tests demand)

### 16.3 Unofficial opcodes

* [ ] Add separate opcode table for unofficial ops
* [ ] Gate behind a flag/config
* [ ] (T) Targeted test ROMs / specific game fixes

---

## 17. Regression Suite (always growing)

* [ ] Add a curated “smoke ROM list” with per-ROM expectations:
  * boots to title
  * renders stable frame hash
  * accepts input
* [ ] Add screenshot golden set for:
  * 1 title screen
  * 1 scrolling scene
  * 1 sprite-heavy scene
  * 1 MMC3 split-scroll scene
* [ ] Add a known-good trace snapshot for one tricky timing case

---

## 18. Nice-to-haves (after core correctness)

* [ ] PAL support (separate timing constants)
* [ ] Configurable palettes + NTSC filter emulation
* [ ] Rewind (ring buffer of save-states)
* [ ] Movie recording / input replay
* [ ] Additional controllers/peripherals
* [ ] UI overlay for FPS, CPU/PPU timing, audio buffer depth
