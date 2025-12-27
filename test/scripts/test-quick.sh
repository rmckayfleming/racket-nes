#!/bin/bash
# Quick smoke test - runs essential tests for fast iteration
# Use this during development to catch obvious regressions

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-common.sh"
parse_test_args "$@"

echo "========================================"
echo "Quick Smoke Test Suite"
if [[ "$PARALLEL" == "1" ]]; then
    echo "(running in parallel with $MAX_JOBS jobs)"
fi
echo "========================================"
echo ""

# Essential CPU tests
echo "--- CPU Basics ---"
smart_test "$TEST_ROMS/instr_test-v5/rom_singles/01-basics.nes" 2000 "CPU basics"
smart_test "$TEST_ROMS/instr_test-v5/rom_singles/15-brk.nes" 2000 "BRK instruction"
smart_test "$TEST_ROMS/instr_test-v5/rom_singles/16-special.nes" 2000 "Special ops"

echo ""
echo "--- PPU Basics ---"
smart_test "$TEST_ROMS/ppu_vbl_nmi/rom_singles/01-vbl_basics.nes" 1500 "VBlank basics"
smart_test "$TEST_ROMS/ppu_vbl_nmi/rom_singles/04-nmi_control.nes" 1500 "NMI control"
smart_test "$TEST_ROMS/sprite_hit_tests_2005.10.05/01.basics.nes" 2000 "Sprite 0 basics"

echo ""
echo "--- APU Basics ---"
smart_test "$TEST_ROMS/apu_test/rom_singles/1-len_ctr.nes" 3000 "Length counter"
smart_test "$TEST_ROMS/apu_test/rom_singles/2-len_table.nes" 3000 "Length table"

finish_tests

print_summary "Quick Smoke Test"

# Return non-zero if any tests failed
if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
