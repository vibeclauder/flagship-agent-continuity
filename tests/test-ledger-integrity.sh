#!/bin/bash
# Verifies the strict revenue-state ledger: valid transitions succeed,
# illegal transitions are rejected, and only `settled` events count as
# recognized revenue (deposits and proposals never do).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LEDGER="$PROJECT_DIR/lib/ledger.js"

RUN_DIR="$PROJECT_DIR/tests/tmp/ledger-integrity-$$"
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"
export RUN_DIR

pass=0
fail=0

expect_ok() {
  local desc="$1"; shift
  if node "$LEDGER" "$@" >/dev/null 2>"$RUN_DIR/last-stderr"; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc (expected success, got error: $(cat "$RUN_DIR/last-stderr"))"
    fail=$((fail + 1))
  fi
}

expect_fail() {
  local desc="$1"; shift
  if node "$LEDGER" "$@" >/dev/null 2>"$RUN_DIR/last-stderr"; then
    echo "FAIL: $desc (expected rejection, but it succeeded)"
    fail=$((fail + 1))
  else
    echo "PASS: $desc (rejected: $(cat "$RUN_DIR/last-stderr"))"
    pass=$((pass + 1))
  fi
}

echo "== valid lifecycle =="
expect_ok "lead is a valid opening state" record opp-1 lead
expect_ok "lead -> qualified is valid" record opp-1 qualified
expect_ok "qualified -> proposal_sent is valid" record opp-1 proposal_sent
expect_ok "proposal_sent -> deposit_received requires amount" record opp-1 deposit_received 500
expect_ok "deposit_received -> settled requires amount" record opp-1 settled 2500

echo "== illegal transitions =="
expect_fail "cannot skip straight to qualified for a new id" record opp-2 qualified
expect_fail "cannot go backwards from settled" record opp-1 qualified

node "$LEDGER" record opp-3 lead >/dev/null 2>&1
expect_fail "cannot jump lead -> settled, skipping the pipeline" record opp-3 settled 999

node "$LEDGER" record opp-4 lead >/dev/null 2>&1
node "$LEDGER" record opp-4 qualified >/dev/null 2>&1
node "$LEDGER" record opp-4 proposal_sent >/dev/null 2>&1
expect_fail "deposit_received with zero amount is rejected" record opp-4 deposit_received 0

node "$LEDGER" record opp-6 lead >/dev/null 2>&1
node "$LEDGER" record opp-6 qualified >/dev/null 2>&1
node "$LEDGER" record opp-6 proposal_sent >/dev/null 2>&1
node "$LEDGER" record opp-6 deposit_received 400 >/dev/null 2>&1
expect_fail "settled requires a positive amount, not omitted" record opp-6 settled

echo "== lost is reachable from any non-terminal state =="
node "$LEDGER" record opp-5 lead >/dev/null 2>&1
expect_ok "lead -> lost is valid" record opp-5 lost
expect_fail "lost is terminal, no further transitions" record opp-5 qualified

echo "== accounting correctness =="
report=$(FORCE_COLOR=0 node "$LEDGER" report)
settled_revenue=$(echo "$report" | FORCE_COLOR=0 node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>console.log(JSON.parse(d).settledRevenue))")
settled_count=$(echo "$report" | FORCE_COLOR=0 node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>console.log(JSON.parse(d).byState.settled||0))")

if [[ "$settled_revenue" == "2500" ]]; then
  echo "PASS: settled revenue is exactly the one settled opportunity (\$2500), not deposits/proposals"
  pass=$((pass + 1))
else
  echo "FAIL: expected settledRevenue=2500, got $settled_revenue"
  fail=$((fail + 1))
fi

if [[ "$settled_count" == "1" ]]; then
  echo "PASS: exactly one opportunity in settled state"
  pass=$((pass + 1))
else
  echo "FAIL: expected 1 settled opportunity, got $settled_count"
  fail=$((fail + 1))
fi

rm -rf "$RUN_DIR"

echo ""
echo "test-ledger-integrity: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
