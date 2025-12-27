#!/bin/bash
# Quick smoke test - runs essential tests for fast iteration
# Use this during development to catch obvious regressions
# Only includes tests that use the Blargg $6000 protocol

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
smart_test "$TEST_ROMS/instr_test-v5/rom_singles/01-basics.nes" 3000 "CPU basics"
smart_test "$TEST_ROMS/instr_test-v5/rom_singles/15-brk.nes" 3000 "BRK instruction"
smart_test "$TEST_ROMS/instr_test-v5/rom_singles/16-special.nes" 3000 "Special ops"

echo ""
echo "--- PPU Basics ---"
smart_test "$TEST_ROMS/ppu_vbl_nmi/rom_singles/01-vbl_basics.nes" 3000 "VBlank basics"
smart_test "$TEST_ROMS/ppu_vbl_nmi/rom_singles/03-vbl_clear_time.nes" 3000 "VBL clear time"

echo ""
echo "--- APU Basics ---"
smart_test "$TEST_ROMS/apu_test/rom_singles/1-len_ctr.nes" 5000 "Length counter"
smart_test "$TEST_ROMS/apu_test/rom_singles/2-len_table.nes" 5000 "Length table"
smart_test "$TEST_ROMS/apu_test/rom_singles/3-irq_flag.nes" 5000 "IRQ flag"

finish_tests

print_summary "Quick Smoke Test"

# Return non-zero if any tests failed
if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
