#!/bin/zsh
# Generic continuity watchdog.
#
# Reference implementation of the pattern used by the real
# ai-implementation-studio/WATCHDOG.sh: poll for a live worker, launch a
# successor if none is running, launch a recovery successor if the current
# worker has gone quiet for too long, and stop cleanly on a STOP file.
#
# All business-specific details (mission text, prompts, revenue rails) are
# intentionally absent — this demonstrates the continuity mechanism only.
set -u

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
RUN_DIR="${RUN_DIR:-$PROJECT_DIR/run}"
STOP_FILE="$RUN_DIR/STOP"
LOG_FILE="$RUN_DIR/watchdog.log"
LOCK_DIR="$RUN_DIR/.watchdog-lock"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
STALL_SECONDS="${STALL_SECONDS:-30}"
WORKER_MODE="${WORKER_MODE:-complete}"
WORKER_TASKS="${WORKER_TASKS:-3}"
WORKER_LABEL_PREFIX="${WORKER_LABEL_PREFIX:-worker}"
MAX_LAUNCHES="${MAX_LAUNCHES:-0}"   # 0 = unlimited; tests cap this to keep runs finite

mkdir -p "$RUN_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "watchdog already running for $RUN_DIR (lock held)" >&2
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

log_event() {
  print -r -- "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $1" >> "$LOG_FILE"
}

progress_mtime() {
  local f="$RUN_DIR/progress.log"
  [[ -f "$f" ]] && stat -f '%m' "$f" 2>/dev/null || print 0
}

active_pid() {
  FORCE_COLOR=0 node -e "
    const h = require('$PROJECT_DIR/lib/handoff');
    const s = h.readHandoff('$RUN_DIR');
    if (s.activeWorkerPid && h.isAlive(s.activeWorkerPid)) {
      console.log(s.activeWorkerPid);
    }
  "
}

launch_count=0

launch_successor() {
  local reason="$1"
  launch_count=$((launch_count + 1))
  local label="${WORKER_LABEL_PREFIX}-succ-${launch_count}"
  local pid
  pid=$(FORCE_COLOR=0 node -e "
    const h = require('$PROJECT_DIR/lib/handoff');
    const pid = h.launchSuccessor('$RUN_DIR', {
      workerScript: '$PROJECT_DIR/lib/worker.js',
      args: ['--mode=$WORKER_MODE', '--tasks=$WORKER_TASKS', '--label=$label'],
      launchedBy: { reason: '$reason', name: 'watchdog' },
    });
    console.log(pid);
  ")
  log_event "launched successor label=$label pid=$pid reason=\"$reason\""
}

log_event "watchdog started pid=$$ run_dir=$RUN_DIR poll=${POLL_INTERVAL}s stall=${STALL_SECONDS}s"
last_mtime=$(progress_mtime)
last_progress_epoch=$(date +%s)

while [[ ! -e "$STOP_FILE" ]]; do
  now=$(date +%s)
  current_mtime=$(progress_mtime)

  if (( current_mtime > last_mtime )); then
    last_mtime=$current_mtime
    last_progress_epoch=$now
    log_event "progress detected mtime=$current_mtime"
  fi

  pid=$(active_pid)

  if [[ -z "$pid" ]]; then
    log_event "no active worker"
    launch_successor "no active worker"
    last_progress_epoch=$now
  elif (( now - last_progress_epoch >= STALL_SECONDS )); then
    log_event "worker pid=$pid alive but stalled for >= ${STALL_SECONDS}s"
    launch_successor "active worker produced no progress for ${STALL_SECONDS}s"
    last_progress_epoch=$now
  fi

  if (( MAX_LAUNCHES > 0 && launch_count >= MAX_LAUNCHES )); then
    log_event "max_launches reached ($MAX_LAUNCHES), watchdog exiting for test determinism"
    break
  fi

  sleep "$POLL_INTERVAL"
done

if [[ -e "$STOP_FILE" ]]; then
  log_event "watchdog stopped because STOP file exists"
else
  log_event "watchdog exiting"
fi
