#!/bin/bash
# Master test runner - runs all test categories

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           NES Emulator Comprehensive Test Suite              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Track overall results
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_INCONCLUSIVE=0

run_category() {
    local script="$1"
    local name="$2"

    echo ""
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│ $name"
    echo "└──────────────────────────────────────────────────────────────┘"

    if [[ -x "$script" ]]; then
        "$script"
    else
        bash "$script"
    fi
}

# Run each test category
run_category "$SCRIPT_DIR/test-cpu.sh" "CPU Tests"
run_category "$SCRIPT_DIR/test-ppu.sh" "PPU Tests"
run_category "$SCRIPT_DIR/test-apu.sh" "APU Tests"
run_category "$SCRIPT_DIR/test-mappers.sh" "Mapper Tests"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    All Tests Complete                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
