# Test ROMs

This directory is for NES test ROMs used in automated testing.
ROM files are gitignored and must be obtained separately.

## Recommended Test ROMs

### CPU Tests
- **nestest.nes** - Comprehensive CPU instruction test
  - Run in automation mode starting at $C000
  - Reference log: `../reference/nestest.log`
  - Source: https://github.com/christopherpow/nes-test-roms

- **instr_test-v5/** - Official opcode tests by blargg
  - Source: https://github.com/christopherpow/nes-test-roms

### PPU Tests
- **ppu_vbl_nmi/** - VBlank and NMI timing tests
- **sprite_hit_tests/** - Sprite 0 hit detection tests
- **scrolltest.nes** - Scrolling behavior tests

### APU Tests
- **apu_test/** - APU timing and register tests by blargg

### Mapper Tests
- Various mapper-specific test ROMs

## Obtaining ROMs

Test ROMs can be downloaded from:
- https://github.com/christopherpow/nes-test-roms
- https://www.nesdev.org/wiki/Emulator_tests

Commercial game ROMs must be legally obtained from your own cartridges.
