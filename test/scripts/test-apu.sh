#!/bin/bash
# APU tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-common.sh"

echo "========================================"
echo "APU Tests (blargg apu_test)"
echo "========================================"

for rom in "$TEST_ROMS/apu_test/rom_singles"/*.nes; do
    run_test "$rom" 3000
done

print_summary "APU Core"
APU_PASSED=$PASSED
APU_FAILED=$FAILED
reset_counters

echo ""
echo "========================================"
echo "DMC Tests"
echo "========================================"

run_test "$TEST_ROMS/dmc_tests/buffer_retained.nes" 2000 "DMC buffer retained"
run_test "$TEST_ROMS/dmc_tests/latency.nes" 2000 "DMC latency"
run_test "$TEST_ROMS/dmc_tests/status.nes" 2000 "DMC status"
run_test "$TEST_ROMS/dmc_tests/status_irq.nes" 2000 "DMC status IRQ"

print_summary "DMC"
DMC_PASSED=$PASSED
DMC_FAILED=$FAILED
reset_counters

echo ""
echo "========================================"
echo "APU Reset Tests"
echo "========================================"

for rom in "$TEST_ROMS/apu_reset"/*.nes; do
    run_test "$rom" 2000
done

print_summary "APU Reset"
RESET_PASSED=$PASSED
RESET_FAILED=$FAILED

echo ""
echo "========================================"
echo "APU Test Summary"
echo "========================================"
TOTAL_PASSED=$((APU_PASSED + DMC_PASSED + RESET_PASSED))
TOTAL_FAILED=$((APU_FAILED + DMC_FAILED + RESET_FAILED))
echo -e "Total: ${GREEN}$TOTAL_PASSED passed${NC}, ${RED}$TOTAL_FAILED failed${NC}"
