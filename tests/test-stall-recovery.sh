#!/bin/bash
# Simulates a worker that goes quiet while remaining alive (a hang, not a
# crash). Verifies the watchdog's stall detector — not just "is a pid
# alive" but "is a pid alive AND making progress" — fires a recovery
# launch after STALL_SECONDS of silence, and that the recovery is logged
# with the correct reason.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUN_DIR="$PROJECT_DIR/tests/tmp/stall-$$"
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"

pass=0
fail=0
worker_pids=()

cleanup() {
  for p in "${worker_pids[@]}"; do
    kill "$p" 2>/dev/null
    wait "$p" 2>/dev/null
  done
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

# Manually start a worker already in "stall" mode, standing in for a
# session that was mid-task before the watchdog process (re)started —
# the watchdog must be able to detect a stall in a worker it didn't
# itself launch.
RUN_DIR="$RUN_DIR" node "$PROJECT_DIR/lib/worker.js" --mode=stall --tasks=2 --task-delay-ms=50 --label=original-worker &
original_pid=$!
worker_pids+=("$original_pid")

# Let it do its couple of tasks and go quiet.
sleep 1

RUN_DIR="$RUN_DIR" \
POLL_INTERVAL=1 \
STALL_SECONDS=3 \
WORKER_MODE=stall \
WORKER_TASKS=2 \
MAX_LAUNCHES=1 \
  "$PROJECT_DIR/bin/watchdog.sh" >/dev/null 2>&1 &
watchdog_pid=$!

# Watchdog runs to MAX_LAUNCHES=1 and exits on its own; wait for it,
# bounded so the test can never hang.
for _ in $(seq 1 30); do
  kill -0 "$watchdog_pid" 2>/dev/null || break
  sleep 0.5
done

if grep -q 'stalled' "$RUN_DIR/watchdog.log" 2>/dev/null; then
  echo "PASS: watchdog log records the stall detection"
  pass=$((pass + 1))
else
  echo "FAIL: watchdog.log never recorded a stall (contents follow)"
  cat "$RUN_DIR/watchdog.log" 2>/dev/null
  fail=$((fail + 1))
fi

if grep -q "worker pid=$original_pid alive but stalled" "$RUN_DIR/watchdog.log" 2>/dev/null; then
  echo "PASS: watchdog correctly identified the ORIGINAL worker's pid as the stalled one"
  pass=$((pass + 1))
else
  echo "FAIL: watchdog did not name the original worker's pid as stalled"
  fail=$((fail + 1))
fi

if grep -q 'launched successor.*reason="active worker produced no progress' "$RUN_DIR/watchdog.log" 2>/dev/null; then
  echo "PASS: recovery successor was launched with the correct reason"
  pass=$((pass + 1))
else
  echo "FAIL: no recovery successor launch with the expected reason found"
  fail=$((fail + 1))
fi

successor_pid=$(FORCE_COLOR=0 node -e "
  const h = require('$PROJECT_DIR/lib/handoff');
  const s = h.readHandoff('$RUN_DIR');
  console.log(s.activeWorkerPid || '');
" 2>/dev/null)
if [[ -n "$successor_pid" && "$successor_pid" != "$original_pid" ]]; then
  echo "PASS: handoff.json now points at a new successor pid ($successor_pid), distinct from the original ($original_pid)"
  pass=$((pass + 1))
  worker_pids+=("$successor_pid")
else
  echo "FAIL: handoff.json does not show a distinct successor pid"
  fail=$((fail + 1))
fi

echo ""
echo "test-stall-recovery: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
