# CLAUDE.md

NES emulator in Racket using our SDL3 bindings. See PLAN.md for architecture and TODO.md for task breakdown.

## Running Code

**Critical**: Use the Homebrew Racket and set PLTCOLLECTS for local development:

```bash
PLTCOLLECTS="$PWD:" /opt/homebrew/bin/racket main.rkt --rom test/roms/nestest.nes
```

Run tests:
```bash
PLTCOLLECTS="$PWD:" /opt/homebrew/bin/raco test lib/ cart/ nes/
```

First-time setup:
```bash
ln -sf . nes  # Create symlink so collection resolves
```

## Project Structure

| Directory | Purpose |
|-----------|---------|
| `lib/6502/` | Reusable 6502 CPU core (cpu, opcodes, addressing, disasm) |
| `lib/` | Shared utilities (bits, bus, serde) |
| `nes/` | NES-specific: system, memory, dma, openbus |
| `nes/ppu/` | PPU: timing, state, registers, bus |
| `nes/input/` | Controller handling (shift register, button state) |
| `nes/mappers/` | Mapper implementations (nrom, mmc1, uxrom, etc.) |
| `nes/apu/` | APU: registers, channels, mixer, frame counter (not yet implemented) |
| `cart/` | ROM parsing (iNES) and save file handling |
| `frontend/` | SDL3 integration: video, audio, input (not yet implemented) |
| `debug/` | Debugger, trace, save states, viewers (not yet implemented) |
| `test/` | Tests and harnesses |

## Key Design Patterns

**Timing**: Mode A (instruction-stepped) first, Mode B (cycle-interleaved) later.
- CPU executes one instruction, reports cycles consumed
- PPU advances by `cycles * 3`
- APU advances by `cycles`

**Bus**: Handler-based dispatch with mirroring support and open bus behavior.

**Memory map hooks**: Components connect via callback boxes in `nes/memory.rkt`:
- `nes-memory-set-ppu-read!/write!` for PPU registers
- `nes-memory-set-controller-read!/write!` for $4016/$4017
- `nes-memory-set-dma-write!` for $4014 OAM DMA
- `nes-memory-set-cart-read!/write!` for mapper

**Mappers**: Each mapper implements a common interface for PRG/CHR banking, mirroring control, and optional IRQ hooks.

**PPU internal registers**: Uses v/t/x/w scroll registers per loopy docs. Register reads/writes return whether NMI state changed (for edge-triggered NMI).

## Progress Tracking

Check TODO.md for current status and next steps. Update it as you complete tasks.

## Testing

- `nestest.nes` is the primary CPU validation target (5003 official opcode tests pass)
- Reference log at `test/reference/nestest.log`
- ROMs go in `test/roms/` (gitignored, see README there)
- Run `test/harness/nestest.rkt` for CPU validation

## Dependencies

- `sdl3` package (at `../sdl3`, link with `raco pkg install ../sdl3`)

## Conventions

- Module paths use collection-style: `(require nes/ppu/ppu)`
- Mutable state uses `!` suffix: `step!`, `tick!`, `reset!`
- Predicates use `?` suffix: `page-crossed?`
- Use `u8`, `u16` helpers from `lib/bits.rkt` for byte manipulation
- Boxes for mutable fields in structs: `(struct foo (val-box) ...)` with `(unbox (foo-val-box f))`

## Racket Gotchas

- `define` inside `begin` blocks doesn't work - use `let` or `let*` instead
- `(require racket/file)` needed for `file->lines`
- Tests use `(module+ test ...)` submodules
- For iNES test fixtures, create raw bytes with header + PRG data rather than mocking structs
