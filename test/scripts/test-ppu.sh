#!/bin/bash
# PPU tests
#
# Note: Some older test ROMs (sprite_hit_tests_2005, sprite_overflow_tests,
# blargg_ppu_tests_2005) don't use the Blargg $6000 protocol and require
# visual inspection. They are excluded from this automated test suite.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-common.sh"
parse_test_args "$@"

echo "========================================"
echo "PPU VBlank/NMI Tests"
if [[ "$PARALLEL" == "1" ]]; then
    echo "(running in parallel with $MAX_JOBS jobs)"
fi
echo "========================================"

for rom in "$TEST_ROMS/ppu_vbl_nmi/rom_singles"/*.nes; do
    smart_test "$rom" 3000
done
finish_tests

print_summary "VBlank/NMI"
VBL_PASSED=$PASSED
VBL_FAILED=$FAILED
reset_counters

echo ""
echo "========================================"
echo "PPU Test Summary"
echo "========================================"
echo -e "Total: ${GREEN}$VBL_PASSED passed${NC}, ${RED}$VBL_FAILED failed${NC}"
echo ""
echo "Note: sprite_hit_tests_2005, sprite_overflow_tests, and"
echo "blargg_ppu_tests_2005 require visual inspection (no \$6000 protocol)"
