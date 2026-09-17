/// The arithmetic of the wallet, with nothing else in it.
///
/// No database, no HTTP, no clock. This is where a mistake costs the most —
/// money that appears or vanishes — so it is the part that runs entirely in a
/// unit test, and the part that holds the rule everything else is built on:
/// a transfer moves value and creates none.
///
/// Every function takes a `Map<npub, cubes>` and returns a new one. The input
/// is never touched, so a caller that throws half way through has not half
/// changed anybody's balance.

export class LedgerError extends Error {
  constructor(code, message) {
    super(message ?? code);
    this.name = 'LedgerError';
    this.code = code;
  }
}

/// Cubes are whole and positive.
///
/// Floats are refused outright rather than rounded: a rounded amount is a
/// wrong amount that somebody is charged, and it is wrong in a direction
/// nobody chose. `Number.isSafeInteger` also throws out NaN, Infinity, strings
/// and null in one check.
function checkAmount(amount) {
  if (!Number.isSafeInteger(amount) || amount <= 0) {
    throw new LedgerError('amount', `bad amount ${amount}`);
  }
}

/// Lower-case hex, 64 characters — an x-only secp256k1 key as the rest of the
/// app writes it.
///
/// Upper case is refused rather than folded: the same key in two spellings
/// would be two accounts, and the balance would land in whichever one the
/// caller happened to type.
function checkNpub(npub) {
  if (typeof npub !== 'string' || !/^[0-9a-f]{64}$/.test(npub)) {
    throw new LedgerError('npub', 'npub must be 64 lower-case hex characters');
  }
}

export function applyCredit(rows, { npub, amount }) {
  checkNpub(npub);
  checkAmount(amount);
  const next = new Map(rows);
  next.set(npub, (next.get(npub) ?? 0) + amount);
  return next;
}

export function applyDebit(rows, { npub, amount }) {
  checkNpub(npub);
  checkAmount(amount);
  const have = rows.get(npub) ?? 0;
  if (have < amount) {
    throw new LedgerError('insufficient', `has ${have}, needs ${amount}`);
  }
  const next = new Map(rows);
  next.set(npub, have - amount);
  return next;
}

/// Debit first, then credit.
///
/// In that order on purpose: the debit is the step that can refuse, and doing
/// it first means a refusal happens before anything has been added anywhere.
export function applyTransfer(rows, { from, to, amount }) {
  checkNpub(from);
  checkNpub(to);
  if (from === to) throw new LedgerError('self', 'cannot pay yourself');
  return applyCredit(applyDebit(rows, { npub: from, amount }), {
    npub: to,
    amount,
  });
}

/// The store took its money back.
///
/// The balance may go below zero, and that is the point: it owes us until it
/// is topped up again, and [applyDebit] refuses to spend from it meanwhile.
/// What was already bought with those cubes stays bought — reaching back for
/// it is worse than carrying the loss on the rare account that does this
/// deliberately, and that account is visible in the journal by its repeats.
export function applyRefund(rows, { npub, amount }) {
  checkNpub(npub);
  checkAmount(amount);
  const next = new Map(rows);
  next.set(npub, (next.get(npub) ?? 0) - amount);
  return next;
}
