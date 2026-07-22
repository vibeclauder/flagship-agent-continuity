#!/bin/bash
# Runs every test in this suite and prints a final pass/fail summary.
# Exit code is non-zero if any test failed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

tests=(
  test-ledger-integrity.sh
  test-completion.sh
  test-stall-recovery.sh
  test-stop-control.sh
)

overall_pass=0
overall_fail=0

for t in "${tests[@]}"; do
  echo "############################################################"
  echo "# $t"
  echo "############################################################"
  if bash "$t"; then
    overall_pass=$((overall_pass + 1))
  else
    overall_fail=$((overall_fail + 1))
  fi
  echo ""
done

echo "============================================================"
echo "SUITE RESULT: $overall_pass/${#tests[@]} test files passed"
echo "============================================================"

[[ $overall_fail -eq 0 ]]
