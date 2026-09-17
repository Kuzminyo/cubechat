import { DatabaseSync } from 'node:sqlite';

import {
  applyCredit,
  applyDebit,
  applyRefund,
  applyTransfer,
  LedgerError,
} from './ledger.js';

/// The ledger, kept where a power cut cannot take it.
///
/// SQLite rather than the in-memory map the push doorbell gets away with,
/// because losing the last row here is losing somebody's money rather than a
/// line of log. `synchronous = FULL` for the same reason: the traffic is a
/// handful of operations a second and there is nothing to buy with the speed
/// that relaxing it would win.
///
/// **The rules live in `ledger.js`, not in SQL.** Every write loads the rows it
/// touches, runs them through the same functions the unit tests cover, and
/// writes the result back inside one transaction. A second copy of "what a
/// valid amount is", expressed in constraints, would drift from the first one
/// and only the drift would be visible — as a balance nobody can explain.
const SCHEMA = `
  CREATE TABLE IF NOT EXISTS balances (
    npub  TEXT PRIMARY KEY,
    cubes INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS journal (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    at        INTEGER NOT NULL,
    kind      TEXT    NOT NULL,
    from_npub TEXT,
    to_npub   TEXT,
    amount    INTEGER NOT NULL,
    ref       TEXT
  );
  CREATE UNIQUE INDEX IF NOT EXISTS journal_ref
    ON journal(kind, ref) WHERE ref IS NOT NULL;
`;

export function openStore(path) {
  const db = new DatabaseSync(path);
  // WAL is for readers not blocking the writer; FULL is the one that matters.
  // A reply that says "credited" has to survive the machine losing power in
  // the same second.
  db.exec('PRAGMA journal_mode = WAL');
  db.exec('PRAGMA synchronous = FULL');
  db.exec(SCHEMA);

  const readOne = db.prepare('SELECT cubes FROM balances WHERE npub = ?');
  const write = db.prepare(
    'INSERT INTO balances (npub, cubes) VALUES (?, ?) ' +
      'ON CONFLICT(npub) DO UPDATE SET cubes = excluded.cubes',
  );
  const note = db.prepare(
    'INSERT INTO journal (at, kind, from_npub, to_npub, amount, ref) ' +
      'VALUES (?, ?, ?, ?, ?, ?)',
  );
  const seen = db.prepare(
    'SELECT 1 FROM journal WHERE kind = ? AND ref = ? LIMIT 1',
  );
  const history = db.prepare(
    'SELECT * FROM journal WHERE from_npub = ? OR to_npub = ? ' +
      'ORDER BY id DESC LIMIT ?',
  );

  function balanceOf(npub) {
    return readOne.get(npub)?.cubes ?? 0;
  }

  /// Load the accounts an operation touches, apply the rules, write back.
  ///
  /// `ref` makes the whole thing idempotent: a repeat is answered as a success
  /// without touching a balance, because the network losing a reply is
  /// ordinary and the app will send the same thing again.
  function run({ kind, ref, npubs, apply, from = null, to = null, amount }) {
    if (ref != null && seen.get(kind, ref)) return;
    const rows = new Map(npubs.map((n) => [n, balanceOf(n)]));
    // Applied before the transaction opens: a refusal is not a rollback, it is
    // a thing that never started.
    const next = apply(rows);

    db.exec('BEGIN IMMEDIATE');
    try {
      for (const [npub, cubes] of next) write.run(npub, cubes);
      note.run(Date.now(), kind, from, to, amount, ref);
      db.exec('COMMIT');
    } catch (e) {
      db.exec('ROLLBACK');
      throw e;
    }
  }

  return {
    balanceOf,

    /// Cubes bought from a store. `ref` is the store's transaction id.
    credit({ npub, amount, ref, source }) {
      run({
        kind: 'credit',
        ref,
        npubs: [npub],
        to: npub,
        amount,
        apply: (rows) => applyCredit(rows, { npub, amount }),
      });
      return { source };
    },

    /// Cubes spent on something this app sells. `ref` names the thing.
    debit({ npub, amount, ref }) {
      run({
        kind: 'debit',
        ref,
        npubs: [npub],
        from: npub,
        amount,
        apply: (rows) => applyDebit(rows, { npub, amount }),
      });
    },

    transfer({ from, to, amount, ref }) {
      run({
        kind: 'transfer',
        ref,
        npubs: [from, to],
        from,
        to,
        amount,
        apply: (rows) => applyTransfer(rows, { from, to, amount }),
      });
    },

    /// The store took its money back. See [applyRefund] for why this may go
    /// below zero and why what was bought stays bought.
    refund({ npub, amount, ref }) {
      run({
        kind: 'refund',
        ref,
        npubs: [npub],
        from: npub,
        amount,
        apply: (rows) => applyRefund(rows, { npub, amount }),
      });
    },

    /// What this account did, newest first — what a dispute is settled from.
    journal(npub, limit) {
      return history.all(npub, npub, limit);
    },

    close() {
      db.close();
    },
  };
}

export { LedgerError };
