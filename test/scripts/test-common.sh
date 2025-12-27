#!/bin/bash
# Common functions for NES test scripts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROMS="$PROJECT_DIR/test/roms/nes-test-roms"
AUDIO_TESTS="$PROJECT_DIR/test/roms/nes-audio-tests"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
INCONCLUSIVE=0

# Run a single test ROM
# Usage: run_test <rom_path> <frames> [description]
run_test() {
    local rom="$1"
    local frames="$2"
    local desc="${3:-$(basename "$rom")}"

    if [[ ! -f "$rom" ]]; then
        echo -e "${YELLOW}SKIP${NC}: $desc (file not found)"
        return 2
    fi

    local output
    output=$(PLTCOLLECTS="$PROJECT_DIR:" /opt/homebrew/bin/racket "$PROJECT_DIR/main.rkt" \
        --rom "$rom" \
        --headless \
        --frames "$frames" \
        --test-addr 0x6000 2>&1)
    local exit_code=$?

    if echo "$output" | grep -q "^PASS"; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((PASSED++))
        return 0
    elif echo "$output" | grep -q "^FAIL"; then
        echo -e "${RED}FAIL${NC}: $desc"
        echo "$output" | grep -A3 "^FAIL" | sed 's/^/  /'
        ((FAILED++))
        return 1
    elif echo "$output" | grep -q "^INCONCLUSIVE"; then
        echo -e "${YELLOW}INCONCLUSIVE${NC}: $desc"
        ((INCONCLUSIVE++))
        return 2
    else
        echo -e "${YELLOW}UNKNOWN${NC}: $desc"
        ((INCONCLUSIVE++))
        return 2
    fi
}

# Print summary
print_summary() {
    local category="$1"
    echo ""
    echo "========================================="
    echo "$category Results:"
    echo -e "  ${GREEN}Passed${NC}: $PASSED"
    echo -e "  ${RED}Failed${NC}: $FAILED"
    echo -e "  ${YELLOW}Inconclusive${NC}: $INCONCLUSIVE"
    echo "========================================="
}

# Reset counters
reset_counters() {
    PASSED=0
    FAILED=0
    INCONCLUSIVE=0
}
