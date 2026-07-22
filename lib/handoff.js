#!/usr/bin/env node
'use strict';

/**
 * Handoff state manager.
 *
 * Tracks exactly one thing the watchdog needs to make its two decisions:
 *   1. Is there a live worker right now? (pid + liveness check)
 *   2. Is that worker actually making progress, or just alive and stuck?
 *      (mtime of progress.log, written by the worker on every unit of work)
 *
 * handoff.json is the single source of truth for "who is in charge right
 * now" and a full history of every successor launch and why it happened —
 * the append-only `history` array is what makes a chain of handoffs
 * auditable after the fact, mirroring HANDOFF.md's "record both IDs here"
 * rule but machine-readable.
 */

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

function handoffPath(runDir) {
  return path.join(runDir, 'handoff.json');
}

function progressPath(runDir) {
  return path.join(runDir, 'progress.log');
}

function readHandoff(runDir) {
  const file = handoffPath(runDir);
  if (!fs.existsSync(file)) {
    return { activeWorkerPid: null, status: 'idle', history: [] };
  }
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function writeHandoff(runDir, state) {
  fs.writeFileSync(handoffPath(runDir), JSON.stringify(state, null, 2) + '\n');
}

function isAlive(pid) {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return false;
  }
}

function appendProgress(runDir, message) {
  fs.appendFileSync(
    progressPath(runDir),
    `${new Date().toISOString()} ${message}\n`
  );
}

function lastProgressMtime(runDir) {
  const file = progressPath(runDir);
  if (!fs.existsSync(file)) return 0;
  return fs.statSync(file).mtimeMs;
}

function registerStart(runDir, { pid, label }) {
  const state = readHandoff(runDir);
  state.activeWorkerPid = pid;
  state.status = 'working';
  state.startedAt = new Date().toISOString();
  state.label = label;
  state.history = state.history || [];
  state.history.push({
    event: 'start',
    pid,
    label,
    at: state.startedAt,
  });
  writeHandoff(runDir, state);
  return state;
}

function registerComplete(runDir, { pid, summary }) {
  const state = readHandoff(runDir);
  state.status = 'complete';
  state.activeWorkerPid = null;
  state.completedAt = new Date().toISOString();
  state.history = state.history || [];
  state.history.push({
    event: 'complete',
    pid,
    summary,
    at: state.completedAt,
  });
  writeHandoff(runDir, state);
  return state;
}

function registerSuccessor(runDir, { reason, newPid, launchedBy }) {
  const state = readHandoff(runDir);
  state.activeWorkerPid = newPid;
  state.status = 'working';
  state.startedAt = new Date().toISOString();
  state.history = state.history || [];
  state.history.push({
    event: 'successor_launched',
    reason,
    newPid,
    launchedBy,
    at: state.startedAt,
  });
  writeHandoff(runDir, state);
  return state;
}

/**
 * Launch a detached worker process as a successor. Returns the new pid.
 * The caller (watchdog) is responsible for recording the reason.
 */
function launchSuccessor(runDir, { workerScript, args = [], launchedBy }) {
  const child = spawn(process.execPath, [workerScript, ...args], {
    cwd: runDir,
    detached: true,
    stdio: 'ignore',
    env: process.env,
  });
  child.unref();
  registerSuccessor(runDir, { reason: launchedBy.reason, newPid: child.pid, launchedBy: launchedBy.name });
  return child.pid;
}

module.exports = {
  handoffPath,
  progressPath,
  readHandoff,
  writeHandoff,
  isAlive,
  appendProgress,
  lastProgressMtime,
  registerStart,
  registerComplete,
  registerSuccessor,
  launchSuccessor,
};
