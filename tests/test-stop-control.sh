#!/bin/bash
# Verifies explicit stop control: creating the STOP file causes the
# watchdog to exit cleanly on its next poll, and it does so even with
# unlimited launches allowed (MAX_LAUNCHES=0) — stop must win over
# "keep the mission going forever".
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUN_DIR="$PROJECT_DIR/tests/tmp/stop-$$"
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"

pass=0
fail=0

RUN_DIR="$RUN_DIR" \
POLL_INTERVAL=1 \
STALL_SECONDS=3600 \
WORKER_MODE=stall \
WORKER_TASKS=1 \
MAX_LAUNCHES=0 \
  "$PROJECT_DIR/bin/watchdog.sh" >/dev/null 2>&1 &
watchdog_pid=$!

# Let it run at least one poll cycle and launch its first worker.
sleep 2
if kill -0 "$watchdog_pid" 2>/dev/null; then
  echo "PASS: watchdog is running before STOP is created"
  pass=$((pass + 1))
else
  echo "FAIL: watchdog exited prematurely before the STOP test began"
  fail=$((fail + 1))
fi

touch "$RUN_DIR/STOP"

stopped=0
for _ in $(seq 1 20); do
  kill -0 "$watchdog_pid" 2>/dev/null || { stopped=1; break; }
  sleep 0.5
done

if [[ $stopped -eq 1 ]]; then
  echo "PASS: watchdog process exited after STOP file was created"
  pass=$((pass + 1))
else
  echo "FAIL: watchdog is still running 10s after STOP was created"
  fail=$((fail + 1))
  kill "$watchdog_pid" 2>/dev/null
fi

if grep -q 'watchdog stopped because STOP file exists' "$RUN_DIR/watchdog.log" 2>/dev/null; then
  echo "PASS: watchdog logged the STOP-triggered shutdown"
  pass=$((pass + 1))
else
  echo "FAIL: watchdog.log missing the STOP shutdown record"
  fail=$((fail + 1))
fi

# Cleanup any lingering worker left alive by the stalled successor.
worker_pid=$(FORCE_COLOR=0 node -e "
  const h = require('$PROJECT_DIR/lib/handoff');
  const s = h.readHandoff('$RUN_DIR');
  if (s.activeWorkerPid && h.isAlive(s.activeWorkerPid)) console.log(s.activeWorkerPid);
" 2>/dev/null)
[[ -n "$worker_pid" ]] && { kill "$worker_pid" 2>/dev/null; wait "$worker_pid" 2>/dev/null; }

rm -rf "$RUN_DIR"

echo ""
echo "test-stop-control: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
