#!/bin/bash
# Master test runner - runs all test categories
# Supports parallel execution with -j flag

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse args and export for child scripts
export PARALLEL=0
export MAX_JOBS=8

while [[ $# -gt 0 ]]; do
    case $1 in
        -j|--parallel)
            PARALLEL=1
            if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                MAX_JOBS=$2
                shift
            fi
            ;;
    esac
    shift
done

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           NES Emulator Comprehensive Test Suite              ║"
if [[ "$PARALLEL" == "1" ]]; then
echo "║                (parallel mode: $MAX_JOBS jobs)                       ║"
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

run_category() {
    local script="$1"
    local name="$2"

    echo ""
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│ $name"
    echo "└──────────────────────────────────────────────────────────────┘"

    bash "$script"
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
