#!/bin/bash
# Quick smoke test - runs essential tests for fast iteration
# Use this during development to catch obvious regressions

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-common.sh"

echo "========================================"
echo "Quick Smoke Test Suite"
echo "========================================"
echo ""

# Essential CPU tests
echo "--- CPU Basics ---"
run_test "$TEST_ROMS/instr_test-v5/rom_singles/01-basics.nes" 2000 "CPU basics"
run_test "$TEST_ROMS/instr_test-v5/rom_singles/15-brk.nes" 2000 "BRK instruction"
run_test "$TEST_ROMS/instr_test-v5/rom_singles/16-special.nes" 2000 "Special ops"

echo ""
echo "--- PPU Basics ---"
run_test "$TEST_ROMS/ppu_vbl_nmi/rom_singles/01-vbl_basics.nes" 1500 "VBlank basics"
run_test "$TEST_ROMS/ppu_vbl_nmi/rom_singles/04-nmi_control.nes" 1500 "NMI control"
run_test "$TEST_ROMS/sprite_hit_tests_2005.10.05/01.basics.nes" 2000 "Sprite 0 basics"

echo ""
echo "--- APU Basics ---"
run_test "$TEST_ROMS/apu_test/rom_singles/1-len_ctr.nes" 3000 "Length counter"
run_test "$TEST_ROMS/apu_test/rom_singles/2-len_table.nes" 3000 "Length table"

print_summary "Quick Smoke Test"

# Return non-zero if any tests failed
if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
