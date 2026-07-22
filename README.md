# flagship-agent-continuity

Reference implementation of a continuity pattern for long-running, unattended
Claude Code agent sessions: detect a dead or stalled worker, launch a
successor, and keep an auditable record of every handoff. Paired with a
strict revenue-state ledger that refuses to count pipeline activity
(leads, proposals, deposits) as recognized revenue until an opportunity
reaches a terminal `settled` state.

All business-specific detail (mission text, prompts, payment rails) is
intentionally absent — this repo demonstrates the mechanism only.

## Why this exists

Autonomous agent sessions eventually die, hang, or lose their process. A
supervisor needs to answer two questions cheaply and correctly:

1. Is a worker currently alive?
2. Is that worker actually making progress, or just alive and stuck?

`bin/watchdog.sh` polls for both. If no worker is alive, it launches a
successor. If a worker is alive but hasn't written a progress heartbeat
within `STALL_SECONDS`, it treats that as a hang (not a crash) and launches
a recovery successor anyway — the "alive but wedged" failure mode a plain
liveness check misses.

## Layout

- `bin/watchdog.sh` — polls `handoff.json` + `progress.log`, launches
  successors on no-worker or stall, exits cleanly on a `STOP` file.
- `lib/handoff.js` — handoff state: active worker pid, liveness check,
  append-only history of every start/complete/successor event.
- `lib/ledger.js` — append-only JSON-Lines ledger with an explicit state
  machine (`lead -> qualified -> proposal_sent -> deposit_received ->
  settled`, plus `lost` from any non-terminal state). Illegal transitions
  and zero/missing amounts on `deposit_received`/`settled` are rejected,
  not silently accepted.
- `lib/worker.js` — a simulated worker with `complete` / `stall` / `crash`
  modes, used by the tests to exercise every watchdog path deterministically.
- `tests/` — 4 test files, 25 checks: ledger transition/accounting
  correctness, healthy completion, stall detection + recovery, and
  explicit stop control. Run all of them with `tests/run-all.sh`.

## Run it

```sh
tests/run-all.sh
```

Or drive the watchdog directly against a scratch run directory:

```sh
RUN_DIR=./run POLL_INTERVAL=2 STALL_SECONDS=30 bin/watchdog.sh
```

Stop it with `touch ./run/STOP`.
