#!/bin/bash
# PPU tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-common.sh"

echo "========================================"
echo "PPU VBlank/NMI Tests"
echo "========================================"

for rom in "$TEST_ROMS/ppu_vbl_nmi/rom_singles"/*.nes; do
    run_test "$rom" 1500
done

print_summary "VBlank/NMI"
VBL_PASSED=$PASSED
VBL_FAILED=$FAILED
reset_counters

echo ""
echo "========================================"
echo "Sprite 0 Hit Tests"
echo "========================================"

for rom in "$TEST_ROMS/sprite_hit_tests_2005.10.05"/*.nes; do
    run_test "$rom" 2000
done

print_summary "Sprite 0 Hit"
SPR0_PASSED=$PASSED
SPR0_FAILED=$FAILED
reset_counters

echo ""
echo "========================================"
echo "Sprite Overflow Tests"
echo "========================================"

for rom in "$TEST_ROMS/sprite_overflow_tests"/*.nes; do
    run_test "$rom" 2000
done

print_summary "Sprite Overflow"
OVF_PASSED=$PASSED
OVF_FAILED=$FAILED
reset_counters

echo ""
echo "========================================"
echo "PPU Misc Tests (blargg 2005)"
echo "========================================"

run_test "$TEST_ROMS/blargg_ppu_tests_2005.09.15b/palette_ram.nes" 2000 "Palette RAM"
run_test "$TEST_ROMS/blargg_ppu_tests_2005.09.15b/sprite_ram.nes" 2000 "Sprite RAM"
run_test "$TEST_ROMS/blargg_ppu_tests_2005.09.15b/vram_access.nes" 2000 "VRAM access"
run_test "$TEST_ROMS/blargg_ppu_tests_2005.09.15b/vbl_clear_time.nes" 2000 "VBL clear time"
run_test "$TEST_ROMS/blargg_ppu_tests_2005.09.15b/power_up_palette.nes" 2000 "Power-up palette"

print_summary "PPU Misc"
MISC_PASSED=$PASSED
MISC_FAILED=$FAILED

echo ""
echo "========================================"
echo "PPU Test Summary"
echo "========================================"
TOTAL_PASSED=$((VBL_PASSED + SPR0_PASSED + OVF_PASSED + MISC_PASSED))
TOTAL_FAILED=$((VBL_FAILED + SPR0_FAILED + OVF_FAILED + MISC_FAILED))
echo -e "Total: ${GREEN}$TOTAL_PASSED passed${NC}, ${RED}$TOTAL_FAILED failed${NC}"
