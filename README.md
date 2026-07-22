# Agent Continuity Kit

A small, dependency-free reference implementation for keeping an autonomous worker moving when it crashes, stalls, or reaches a handoff boundary.

It demonstrates four operational controls:

- a machine-readable handoff identifying the current worker;
- a progress heartbeat that distinguishes “alive” from “making progress”;
- a watchdog that launches a successor after death or silence;
- an append-only opportunity ledger that never counts pipeline activity as revenue.

This repository was built after a real unattended agent loop stopped while its operator was offline. The tests reproduce successful completion, a live-but-stalled worker, explicit shutdown, and accounting-integrity failures.

## Quick verification

Requirements: macOS, Node.js 18+, Bash, and Zsh. No package installation is required.

```bash
git clone https://github.com/vibeclauder/flagship-agent-continuity.git
cd flagship-agent-continuity
bash tests/run-all.sh
```

The suite exits nonzero on failure. It verifies:

- legal and illegal opportunity-state transitions;
- recognition of revenue only after settlement;
- rejection of missing, zero, and nonnumeric payment amounts;
- successful worker completion without false stall detection;
- recovery from a worker that remains alive but stops writing progress;
- shutdown when an operator creates the `STOP` file.

## Run the demonstration

Healthy completion:

```bash
RUN_DIR="$PWD/run" \
POLL_INTERVAL=1 \
STALL_SECONDS=10 \
WORKER_MODE=complete \
MAX_LAUNCHES=1 \
  ./bin/watchdog.sh
```

Stall recovery:

```bash
RUN_DIR="$PWD/run" \
POLL_INTERVAL=1 \
STALL_SECONDS=3 \
WORKER_MODE=stall \
MAX_LAUNCHES=2 \
  ./bin/watchdog.sh
```

Create `run/STOP` to stop an unlimited watchdog loop.

## Components

| Component | Responsibility |
|---|---|
| `lib/handoff.js` | Records worker ownership, liveness, progress, completion, and successor history. |
| `bin/watchdog.sh` | Polls liveness and progress age, launches a successor, logs the reason, and honors `STOP`. |
| `lib/worker.js` | Simulates healthy, crashed, and stalled workers for deterministic failure testing. |
| `lib/ledger.js` | Replays an append-only JSONL event log and recognizes only settled revenue. |
| `tests/` | Exercises completion, stall recovery, stop control, and ledger invariants end to end. |

## Accounting invariant

```text
lead -> qualified -> proposal_sent -> deposit_received -> settled
  \         \              \                    \
   +-> lost  +-> lost        +-> lost             +-> lost
```

Only a terminal `settled` event with a positive finite amount contributes to `settledRevenue`. Leads, proposals, deposits, application values, and simulated opportunity values are not treated as earned money.

## Simulation disclosure

`lib/worker.js` uses fabricated opportunity IDs and amounts to test state transitions. Those values are test fixtures—not clients, contracts, deposits, or real revenue. The kit contains no credentials, customer information, payment details, or production business data.

## Adapting it to a real orchestrator

Replace the simulated worker launcher with your agent runtime while preserving the protocol:

1. Register the successor and its process/session identifier.
2. Write a heartbeat only after material progress, not merely on a timer.
3. Persist a concise mission handoff before context or usage exhaustion.
4. Log why every successor was launched.
5. Require an explicit operator-controlled stop mechanism.
6. Keep commercial accounting separate from agent activity metrics.

For a distributed deployment, replace local JSON/JSONL files and PID checks with transactional storage, leases, idempotency keys, and runtime-native health checks. This repository is a single-host reference pattern, not a claim of production-grade distributed consensus.

## Known boundary

The watchdog starts a successor when a stalled process remains alive; an integration adapter should terminate or quarantine the superseded worker after verifying the handoff. That policy is runtime-specific and deliberately not guessed here.

## License

MIT
