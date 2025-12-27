#!/bin/bash
# CPU instruction and timing tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-common.sh"

echo "========================================"
echo "CPU Instruction Tests (instr_test-v5)"
echo "========================================"

for rom in "$TEST_ROMS/instr_test-v5/rom_singles"/*.nes; do
    run_test "$rom" 3000
done

print_summary "CPU Instructions"
INSTR_PASSED=$PASSED
INSTR_FAILED=$FAILED
reset_counters

echo ""
echo "========================================"
echo "CPU Timing Tests"
echo "========================================"

# Instruction timing
run_test "$TEST_ROMS/instr_timing/rom_singles/1-instr_timing.nes" 5000 "Instruction timing"
run_test "$TEST_ROMS/instr_timing/rom_singles/2-branch_timing.nes" 5000 "Branch timing"

# Branch timing tests
run_test "$TEST_ROMS/branch_timing_tests/1.Branch_Basics.nes" 2000 "Branch basics"
run_test "$TEST_ROMS/branch_timing_tests/2.Backward_Branch.nes" 2000 "Backward branch"
run_test "$TEST_ROMS/branch_timing_tests/3.Forward_Branch.nes" 2000 "Forward branch"

print_summary "CPU Timing"
TIMING_PASSED=$PASSED
TIMING_FAILED=$FAILED
reset_counters

echo ""
echo "========================================"
echo "CPU Interrupt Tests"
echo "========================================"

for rom in "$TEST_ROMS/cpu_interrupts_v2/rom_singles"/*.nes; do
    run_test "$rom" 3000
done

print_summary "CPU Interrupts"
INT_PASSED=$PASSED
INT_FAILED=$FAILED
reset_counters

echo ""
echo "========================================"
echo "CPU Misc Tests"
echo "========================================"

run_test "$TEST_ROMS/cpu_dummy_reads/cpu_dummy_reads.nes" 3000 "Dummy reads"
run_test "$TEST_ROMS/cpu_dummy_writes/cpu_dummy_writes_oam.nes" 3000 "Dummy writes (OAM)"
run_test "$TEST_ROMS/cpu_dummy_writes/cpu_dummy_writes_ppumem.nes" 3000 "Dummy writes (PPU mem)"

for rom in "$TEST_ROMS/instr_misc/rom_singles"/*.nes; do
    run_test "$rom" 3000
done

print_summary "CPU Misc"
MISC_PASSED=$PASSED
MISC_FAILED=$FAILED

echo ""
echo "========================================"
echo "CPU Test Summary"
echo "========================================"
TOTAL_PASSED=$((INSTR_PASSED + TIMING_PASSED + INT_PASSED + MISC_PASSED))
TOTAL_FAILED=$((INSTR_FAILED + TIMING_FAILED + INT_FAILED + MISC_FAILED))
echo -e "Total: ${GREEN}$TOTAL_PASSED passed${NC}, ${RED}$TOTAL_FAILED failed${NC}"
