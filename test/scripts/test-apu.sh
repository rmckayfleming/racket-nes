#!/bin/bash
# APU tests
#
# Note: dmc_tests don't use Blargg $6000 protocol (visual only).
# APU reset tests require actual reset button which we can't automate.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-common.sh"
parse_test_args "$@"

echo "========================================"
echo "APU Tests (blargg apu_test)"
if [[ "$PARALLEL" == "1" ]]; then
    echo "(running in parallel with $MAX_JOBS jobs)"
fi
echo "========================================"

for rom in "$TEST_ROMS/apu_test/rom_singles"/*.nes; do
    smart_test "$rom" 5000
done
finish_tests

print_summary "APU Core"
APU_PASSED=$PASSED
APU_FAILED=$FAILED
reset_counters

echo ""
echo "========================================"
echo "APU Test Summary"
echo "========================================"
echo -e "Total: ${GREEN}$APU_PASSED passed${NC}, ${RED}$APU_FAILED failed${NC}"
echo ""
echo "Note: dmc_tests and apu_reset require visual inspection or reset button"
