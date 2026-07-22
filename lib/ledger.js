#!/usr/bin/env node
'use strict';

/**
 * Strict revenue-state ledger.
 *
 * Design intent (this is the part real business ledgers get wrong):
 * activity is not revenue. An opportunity only contributes to recognized
 * revenue once it reaches the terminal `settled` state, and only once.
 * Every other state (lead, qualified, proposal_sent, deposit_received) is
 * pipeline, tracked separately, never summed into revenue.
 *
 * Storage: append-only JSON-Lines file. Nothing is ever rewritten in place;
 * corrections are new events. Current state per opportunity is derived by
 * replaying the log, so the log itself is the audit trail.
 */

const fs = require('fs');
const path = require('path');

const TRANSITIONS = {
  lead: ['qualified', 'lost'],
  qualified: ['proposal_sent', 'lost'],
  proposal_sent: ['deposit_received', 'lost'],
  deposit_received: ['settled', 'lost'],
  settled: [],
  lost: [],
};

const START_STATE = 'lead';

function ledgerPath(runDir) {
  return path.join(runDir, 'ledger.jsonl');
}

function readEvents(runDir) {
  const file = ledgerPath(runDir);
  if (!fs.existsSync(file)) return [];
  return fs
    .readFileSync(file, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function deriveState(events) {
  const opportunities = new Map();
  for (const ev of events) {
    const prior = opportunities.get(ev.id);
    opportunities.set(ev.id, {
      id: ev.id,
      state: ev.state,
      amount: ev.amount != null ? ev.amount : prior ? prior.amount : null,
      label: ev.label || (prior ? prior.label : ev.id),
      history: [...(prior ? prior.history : []), ev.state],
      lastEventAt: ev.at,
    });
  }
  return opportunities;
}

/**
 * Validate and append one event. Throws on any rule violation instead of
 * writing a partial/ambiguous record — an accounting ledger must fail
 * closed, not silently accept a bad transition.
 */
function record(runDir, { id, toState, amount, label, at }) {
  if (!id) throw new Error('record() requires an opportunity id');
  if (!TRANSITIONS[toState]) {
    throw new Error(`unknown state "${toState}"`);
  }

  const events = readEvents(runDir);
  const opportunities = deriveState(events);
  const existing = opportunities.get(id);
  const fromState = existing ? existing.state : null;

  if (!existing) {
    if (toState !== START_STATE) {
      throw new Error(
        `opportunity "${id}" does not exist yet; first event must be "${START_STATE}", got "${toState}"`
      );
    }
  } else {
    const allowed = TRANSITIONS[fromState] || [];
    if (!allowed.includes(toState)) {
      throw new Error(
        `illegal transition for "${id}": "${fromState}" -> "${toState}" (allowed: ${
          allowed.length ? allowed.join(', ') : 'none, terminal state'
        })`
      );
    }
  }

  if (toState === 'settled' && (amount == null || amount <= 0)) {
    throw new Error('settled events require a positive amount');
  }
  if (toState === 'deposit_received' && (amount == null || amount <= 0)) {
    throw new Error('deposit_received events require a positive amount');
  }

  const event = {
    id,
    state: toState,
    amount: amount != null ? amount : null,
    label: label || (existing ? existing.label : id),
    at: at || new Date().toISOString(),
  };

  fs.appendFileSync(ledgerPath(runDir), JSON.stringify(event) + '\n');
  return event;
}

function report(runDir) {
  const events = readEvents(runDir);
  const opportunities = deriveState(events);
  const byState = {};
  let settledRevenue = 0;
  let depositsHeld = 0;

  for (const opp of opportunities.values()) {
    byState[opp.state] = (byState[opp.state] || 0) + 1;
    if (opp.state === 'settled') settledRevenue += opp.amount || 0;
    if (opp.state === 'deposit_received') depositsHeld += opp.amount || 0;
  }

  return {
    totalOpportunities: opportunities.size,
    byState,
    settledRevenue,
    depositsHeld,
    opportunities: Array.from(opportunities.values()),
  };
}

function status(runDir, id) {
  const opportunities = deriveState(readEvents(runDir));
  return opportunities.get(id) || null;
}

// --- CLI -------------------------------------------------------------
function main(argv) {
  const [cmd, ...rest] = argv;
  const runDir = process.env.RUN_DIR || process.cwd();

  if (cmd === 'record') {
    const [id, toState, amountRaw, label] = rest;
    const amount = amountRaw != null && amountRaw !== '' ? Number(amountRaw) : null;
    const at = process.env.LEDGER_AT || new Date().toISOString();
    const event = record(runDir, { id, toState, amount, label, at });
    console.log(JSON.stringify(event));
    return;
  }

  if (cmd === 'status') {
    const [id] = rest;
    console.log(JSON.stringify(status(runDir, id), null, 2));
    return;
  }

  if (cmd === 'report') {
    console.log(JSON.stringify(report(runDir), null, 2));
    return;
  }

  console.error('usage: ledger.js record <id> <state> [amount] [label]');
  console.error('       ledger.js status <id>');
  console.error('       ledger.js report');
  process.exitCode = 1;
}

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (err) {
    console.error(`ledger error: ${err.message}`);
    process.exitCode = 1;
  }
}

module.exports = { record, report, status, readEvents, deriveState, TRANSITIONS };
