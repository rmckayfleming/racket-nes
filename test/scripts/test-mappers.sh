#!/bin/bash
# Mapper tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-common.sh"
parse_test_args "$@"

echo "========================================"
echo "MMC1 Tests"
if [[ "$PARALLEL" == "1" ]]; then
    echo "(running in parallel with $MAX_JOBS jobs)"
fi
echo "========================================"

smart_test "$TEST_ROMS/MMC1_A12/mmc1_a12.nes" 3000 "MMC1 A12"

# Holy Diver Batman MMC1 test if available
if [[ -f "$TEST_ROMS/holy_diver_batman/M1_P128K.nes" ]]; then
    smart_test "$TEST_ROMS/holy_diver_batman/M1_P128K.nes" 2000 "Holy Diver Batman (MMC1)"
fi
finish_tests

print_summary "MMC1"
MMC1_PASSED=$PASSED
MMC1_FAILED=$FAILED
reset_counters

echo ""
echo "========================================"
echo "MMC3 Tests"
echo "========================================"

for rom in "$TEST_ROMS/mmc3_test"/*.nes; do
    smart_test "$rom" 3000
done
finish_tests

print_summary "MMC3"
MMC3_PASSED=$PASSED
MMC3_FAILED=$FAILED

echo ""
echo "========================================"
echo "Mapper Test Summary"
echo "========================================"
TOTAL_PASSED=$((MMC1_PASSED + MMC3_PASSED))
TOTAL_FAILED=$((MMC1_FAILED + MMC3_FAILED))
echo -e "Total: ${GREEN}$TOTAL_PASSED passed${NC}, ${RED}$TOTAL_FAILED failed${NC}"
