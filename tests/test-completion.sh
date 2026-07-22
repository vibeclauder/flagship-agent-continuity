#!/bin/bash
# Simulates a worker that completes its bounded task list successfully.
# Verifies: the watchdog launches it (no active worker at start), the
# ledger ends with the expected settled revenue, and the watchdog never
# fires a "stalled" recovery launch during a healthy run.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUN_DIR="$PROJECT_DIR/tests/tmp/completion-$$"
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"

pass=0
fail=0

RUN_DIR="$RUN_DIR" \
POLL_INTERVAL=1 \
STALL_SECONDS=30 \
WORKER_MODE=complete \
WORKER_TASKS=3 \
MAX_LAUNCHES=1 \
  "$PROJECT_DIR/bin/watchdog.sh" >/dev/null 2>&1

# Give the launched worker (task-delay 200ms x 3 tasks) time to finish
# and write its completion record.
for _ in $(seq 1 30); do
  status=$(FORCE_COLOR=0 node -e "console.log(require('$PROJECT_DIR/lib/handoff').readHandoff('$RUN_DIR').status)" 2>/dev/null)
  [[ "$status" == "complete" ]] && break
  sleep 0.2
done

if [[ "$status" == "complete" ]]; then
  echo "PASS: worker reached 'complete' status in handoff.json"
  pass=$((pass + 1))
else
  echo "FAIL: worker never reached 'complete' status (last seen: $status)"
  fail=$((fail + 1))
fi

report=$(RUN_DIR="$RUN_DIR" FORCE_COLOR=0 node "$PROJECT_DIR/lib/ledger.js" report 2>/dev/null)
if [[ "$(RUN_DIR=$RUN_DIR FORCE_COLOR=0 node -e "console.log(JSON.parse(process.argv[1]).settledRevenue)" "$report")" == "3750" ]]; then
  echo "PASS: settled revenue is exactly 3 x \$1250 = \$3750"
  pass=$((pass + 1))
else
  echo "FAIL: unexpected settled revenue in report: $report"
  fail=$((fail + 1))
fi

if grep -q 'launched successor.*reason="no active worker"' "$RUN_DIR/watchdog.log"; then
  echo "PASS: watchdog log shows the initial launch reason was 'no active worker', not a stall"
  pass=$((pass + 1))
else
  echo "FAIL: expected an initial 'no active worker' launch entry in watchdog.log"
  fail=$((fail + 1))
fi

if grep -q 'stalled' "$RUN_DIR/watchdog.log"; then
  echo "FAIL: watchdog.log reports a stall during a healthy completion run"
  fail=$((fail + 1))
else
  echo "PASS: no stall was ever reported during a healthy completion run"
  pass=$((pass + 1))
fi

# Cleanup: nothing should still be running, but be defensive.
pid=$(FORCE_COLOR=0 node -e "
  const h = require('$PROJECT_DIR/lib/handoff');
  const s = h.readHandoff('$RUN_DIR');
  if (s.activeWorkerPid && h.isAlive(s.activeWorkerPid)) console.log(s.activeWorkerPid);
" 2>/dev/null)
[[ -n "$pid" ]] && kill "$pid" 2>/dev/null

rm -rf "$RUN_DIR"

echo ""
echo "test-completion: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
