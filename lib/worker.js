#!/usr/bin/env node
'use strict';

/**
 * Simulated autonomous worker agent.
 *
 * This stands in for "a Claude background session doing the mission" in
 * the real system. It does bounded, observable units of work (moving
 * opportunities through the ledger) and writes a progress heartbeat after
 * each one, so the watchdog's stall detector has something real to watch.
 *
 * Modes (via --mode, default "complete"):
 *   complete  - do all tasks, mark itself done, exit 0. The healthy path.
 *   stall     - do a couple of tasks, then go quiet while staying alive
 *               (pid alive, no more progress writes). This is the
 *               "worker is stuck, not dead" case the watchdog's
 *               STALL_SECONDS check exists for.
 *   crash     - exit non-zero immediately with no completion record. This
 *               is the "worker is dead" case the watchdog's
 *               active-worker-pid liveness check exists for.
 */

const handoff = require('./handoff');
const ledger = require('./ledger');

function parseArgs(argv) {
  const opts = { mode: 'complete', tasks: 3, taskDelayMs: 200, label: 'worker' };
  for (const arg of argv) {
    const [key, value] = arg.replace(/^--/, '').split('=');
    if (key === 'mode') opts.mode = value;
    if (key === 'tasks') opts.tasks = Number(value);
    if (key === 'task-delay-ms') opts.taskDelayMs = Number(value);
    if (key === 'label') opts.label = value;
  }
  return opts;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function runComplete(runDir, opts) {
  for (let i = 1; i <= opts.tasks; i += 1) {
    const id = `opp-${i}`;
    ledger.record(runDir, { id, toState: 'lead' });
    ledger.record(runDir, { id, toState: 'qualified' });
    ledger.record(runDir, { id, toState: 'proposal_sent' });
    ledger.record(runDir, { id, toState: 'deposit_received', amount: 1250 });
    ledger.record(runDir, { id, toState: 'settled', amount: 1250 });
    handoff.appendProgress(runDir, `${opts.label} settled ${id} ($1250)`);
    await sleep(opts.taskDelayMs);
  }
  handoff.registerComplete(runDir, {
    pid: process.pid,
    summary: `${opts.label} settled ${opts.tasks} opportunities`,
  });
}

async function runStall(runDir, opts) {
  const stallAfter = Math.max(1, Math.floor(opts.tasks / 2));
  for (let i = 1; i <= stallAfter; i += 1) {
    const id = `opp-${i}`;
    ledger.record(runDir, { id, toState: 'lead' });
    ledger.record(runDir, { id, toState: 'qualified' });
    handoff.appendProgress(runDir, `${opts.label} qualified ${id}`);
    await sleep(opts.taskDelayMs);
  }
  handoff.appendProgress(runDir, `${opts.label} going quiet (simulated stall)`);
  // Stay alive indefinitely without further progress writes. The process
  // is still running (a real pid the watchdog can see), it just never
  // does anything else — exactly the failure mode STALL_SECONDS exists
  // to catch. A very long sleep stands in for "forever" in a demo.
  await sleep(1000 * 60 * 60);
}

async function runCrash() {
  process.stderr.write('simulated crash: exiting without completing\n');
  process.exit(1);
}

async function main() {
  const runDir = process.env.RUN_DIR || process.cwd();
  const opts = parseArgs(process.argv.slice(2));

  handoff.registerStart(runDir, { pid: process.pid, label: opts.label });
  handoff.appendProgress(runDir, `${opts.label} started (mode=${opts.mode}, pid=${process.pid})`);

  if (opts.mode === 'crash') {
    await runCrash();
    return;
  }
  if (opts.mode === 'stall') {
    await runStall(runDir, opts);
    return;
  }
  await runComplete(runDir, opts);
}

if (require.main === module) {
  main().catch((err) => {
    process.stderr.write(`worker error: ${err.message}\n`);
    process.exitCode = 1;
  });
}

module.exports = { parseArgs };
