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

# Parallel execution support
PARALLEL=${PARALLEL:-0}  # Set PARALLEL=1 to enable, or use -j flag
MAX_JOBS=${MAX_JOBS:-8}  # Maximum parallel jobs
declare -a PIDS=()
declare -a RESULTS_FILES=()

# Run a single test ROM (blocking)
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
        --accurate
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

# Run a single test ROM in background (for parallel execution)
# Usage: run_test_async <rom_path> <frames> [description]
run_test_async() {
    local rom="$1"
    local frames="$2"
    local desc="${3:-$(basename "$rom")}"

    if [[ ! -f "$rom" ]]; then
        echo -e "${YELLOW}SKIP${NC}: $desc (file not found)"
        return 2
    fi

    # Create temp file for results
    local result_file=$(mktemp)
    RESULTS_FILES+=("$result_file")

    # Run in background
    (
        local output
        output=$(PLTCOLLECTS="$PROJECT_DIR:" /opt/homebrew/bin/racket "$PROJECT_DIR/main.rkt" \
            --rom "$rom" \
            --headless \
            --frames "$frames" \
            --test-addr 0x6000 2>&1)

        if echo "$output" | grep -q "^PASS"; then
            echo "PASS|$desc|" > "$result_file"
        elif echo "$output" | grep -q "^FAIL"; then
            local details=$(echo "$output" | grep -A3 "^FAIL" | tr '\n' '§')
            echo "FAIL|$desc|$details" > "$result_file"
        elif echo "$output" | grep -q "^INCONCLUSIVE"; then
            echo "INCONCLUSIVE|$desc|" > "$result_file"
        else
            echo "UNKNOWN|$desc|" > "$result_file"
        fi
    ) &

    PIDS+=($!)

    # Throttle if we have too many jobs
    if [[ ${#PIDS[@]} -ge $MAX_JOBS ]]; then
        wait_for_jobs
    fi
}

# Wait for all background jobs and collect results
wait_for_jobs() {
    # Wait for all PIDs
    for pid in "${PIDS[@]}"; do
        wait "$pid" 2>/dev/null
    done

    # Process results
    for result_file in "${RESULTS_FILES[@]}"; do
        if [[ -f "$result_file" ]]; then
            local line=$(cat "$result_file")
            local status=$(echo "$line" | cut -d'|' -f1)
            local desc=$(echo "$line" | cut -d'|' -f2)
            local details=$(echo "$line" | cut -d'|' -f3 | tr '§' '\n')

            case "$status" in
                PASS)
                    echo -e "${GREEN}PASS${NC}: $desc"
                    ((PASSED++))
                    ;;
                FAIL)
                    echo -e "${RED}FAIL${NC}: $desc"
                    if [[ -n "$details" ]]; then
                        echo "$details" | sed 's/^/  /'
                    fi
                    ((FAILED++))
                    ;;
                INCONCLUSIVE)
                    echo -e "${YELLOW}INCONCLUSIVE${NC}: $desc"
                    ((INCONCLUSIVE++))
                    ;;
                *)
                    echo -e "${YELLOW}UNKNOWN${NC}: $desc"
                    ((INCONCLUSIVE++))
                    ;;
            esac
            rm -f "$result_file"
        fi
    done

    # Clear arrays
    PIDS=()
    RESULTS_FILES=()
}

# Smart test runner - uses parallel if enabled
# Usage: smart_test <rom_path> <frames> [description]
smart_test() {
    if [[ "$PARALLEL" == "1" ]]; then
        run_test_async "$@"
    else
        run_test "$@"
    fi
}

# Finish all pending parallel tests
finish_tests() {
    if [[ "$PARALLEL" == "1" ]]; then
        wait_for_jobs
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

# Parse command line args for parallel flag
parse_test_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -j|--parallel)
                PARALLEL=1
                if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                    MAX_JOBS=$2
                    shift
                fi
                ;;
            *)
                ;;
        esac
        shift
    done
}
