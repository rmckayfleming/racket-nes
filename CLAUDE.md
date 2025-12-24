# CLAUDE.md

NES emulator in Racket using our SDL3 bindings. See PLAN.md for architecture and TODO.md for task breakdown.

## Running Code

**Critical**: Use the Homebrew Racket and set PLTCOLLECTS for local development:

```bash
PLTCOLLECTS="$PWD:" /opt/homebrew/bin/racket main.rkt --rom test/roms/nestest.nes
```

Run tests:
```bash
PLTCOLLECTS="$PWD:" /opt/homebrew/bin/raco test test/
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
| `nes/ppu/` | PPU: registers, rendering, timing, palette |
| `nes/apu/` | APU: registers, channels, mixer, frame counter |
| `nes/input/` | Controller handling |
| `nes/mappers/` | Mapper implementations (nrom, mmc1, uxrom, etc.) |
| `cart/` | ROM parsing (iNES) and save file handling |
| `frontend/` | SDL3 integration: video, audio, input |
| `debug/` | Debugger, trace, save states, viewers |
| `test/` | Tests and harnesses |

## Key Design Patterns

**Timing**: Mode A (instruction-stepped) first, Mode B (cycle-interleaved) later.
- CPU executes one instruction, reports cycles consumed
- PPU advances by `cycles * 3`
- APU advances by `cycles`

**Bus**: Handler-based dispatch with mirroring support and open bus behavior.

**Mappers**: Each mapper implements a common interface for PRG/CHR banking, mirroring control, and optional IRQ hooks.

## Testing

- `nestest.nes` is the primary CPU validation target
- Reference log goes in `test/reference/nestest.log`
- ROMs go in `test/roms/` (gitignored, see README there)

## Dependencies

- `sdl3` package (at `../sdl3`, link with `raco pkg install ../sdl3`)

## Conventions

- Module paths use collection-style: `(require nes/ppu/ppu)`
- Mutable state uses `!` suffix: `step!`, `tick!`, `reset!`
- Predicates use `?` suffix: `page-crossed?`
- Use `u8`, `u16` helpers from `lib/bits.rkt` for byte manipulation
