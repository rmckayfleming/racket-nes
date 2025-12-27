#!/bin/bash
# Mapper tests
#
# Note: MMC1_A12 test doesn't use Blargg $6000 protocol (visual only)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-common.sh"
parse_test_args "$@"

echo "========================================"
echo "MMC3 Tests"
if [[ "$PARALLEL" == "1" ]]; then
    echo "(running in parallel with $MAX_JOBS jobs)"
fi
echo "========================================"

for rom in "$TEST_ROMS/mmc3_test"/*.nes; do
    smart_test "$rom" 5000
done
finish_tests

print_summary "MMC3"
MMC3_PASSED=$PASSED
MMC3_FAILED=$FAILED

echo ""
echo "========================================"
echo "Mapper Test Summary"
echo "========================================"
echo -e "Total: ${GREEN}$MMC3_PASSED passed${NC}, ${RED}$MMC3_FAILED failed${NC}"
echo ""
echo "Note: MMC1_A12 requires visual inspection (no \$6000 protocol)"
