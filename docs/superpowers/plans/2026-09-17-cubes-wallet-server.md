# Сервер-кошелёк кубиков — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** довести кошелёк до работающего начисления и перевода, которых **ничто
в приложении ещё не тратит** — чтобы проверить деньги на живых сторах раньше,
чем от них что-то начнёт зависеть.

**Architecture:** отдельный сервис рядом с `push/`, той же формы: Node ESM,
`node --test`, HTTP на `node:http`, авторизация подписанным Nostr-событием через
тот же `verifyEvent`. Реестр в SQLite, потому что это деньги: потеря записи
здесь — это потеря чужих денег, а не строчки лога. Вся арифметика вынесена в
чистые функции и проверяется без HTTP и без базы.

**Tech Stack:** Node >= 20, `@noble/curves`, `@noble/hashes`, `better-sqlite3`,
`node:test`.

**Spec:** `docs/superpowers/specs/2026-09-17-cubes-currency-design.md`

## Global Constraints

- Сервис не падает вместе с `push/` и не роняет его: отдельный процесс,
  отдельная база, отдельный unit systemd.
- **Баланс никогда не создаётся и не исчезает.** Любая операция либо меняет две
  строки на равные противоположные величины, либо одну — и только при
  начислении из стора или возврате.
- Каждая операция с чеком стора идемпотентна по идентификатору транзакции.
- Ни один эндпоинт не верит `npub` из тела запроса: владение ключом
  доказывается подписью события, как в `push/`.
- Отрицательный баланс возможен только после возврата и блокирует траты. Он
  **не** отменяет то, что уже выдано.
- Все суммы — целые кубики. Никаких дробей и никаких чисел с плавающей точкой
  нигде на пути.
- В приложении на этом этапе не меняется ничего.

---

### Task 1: Реестр как чистые функции

Арифметика денег отдельно от базы и от сети — её можно проверить целиком, и
именно в ней ошибка стоит дороже всего.

**Files:**
- Create: `wallet/src/ledger.js`
- Test: `wallet/test/ledger.test.js`

**Interfaces:**
- Consumes: ничего.
- Produces: `applyCredit(rows, {npub, amount})`,
  `applyDebit(rows, {npub, amount})`,
  `applyTransfer(rows, {from, to, amount})`,
  `applyRefund(rows, {npub, amount})` — каждая принимает и возвращает
  `Map<npub, number>`, не меняя вход; бросает `LedgerError` с полем `code`.

- [ ] **Step 1: Write the failing test**

Создать `wallet/test/ledger.test.js`:

```js
import assert from 'node:assert/strict';
import test from 'node:test';
import { applyCredit, applyDebit, applyTransfer, applyRefund, LedgerError }
  from '../src/ledger.js';

const A = 'a'.repeat(64);
const B = 'b'.repeat(64);

test('a credit adds to an account that did not exist', () => {
  const after = applyCredit(new Map(), { npub: A, amount: 100 });
  assert.equal(after.get(A), 100);
});

test('a transfer moves value and creates none', () => {
  // The invariant the whole service exists to keep: the sum before equals the
  // sum after. A bug that breaks it prints money.
  const before = new Map([[A, 100], [B, 5]]);
  const after = applyTransfer(before, { from: A, to: B, amount: 30 });
  const sum = (m) => [...m.values()].reduce((a, b) => a + b, 0);
  assert.equal(sum(after), sum(before));
  assert.equal(after.get(A), 70);
  assert.equal(after.get(B), 35);
});

test('the input is not mutated', () => {
  const before = new Map([[A, 100]]);
  applyTransfer(before, { from: A, to: B, amount: 30 });
  assert.equal(before.get(A), 100);
});

test('a transfer beyond the balance is refused, not overdrawn', () => {
  const before = new Map([[A, 10]]);
  assert.throws(
    () => applyTransfer(before, { from: A, to: B, amount: 11 }),
    (e) => e instanceof LedgerError && e.code === 'insufficient',
  );
});

test('a refund may push the balance below zero', () => {
  // The store took the money back after the cubes were spent. The balance owes
  // us; what was already bought with them stays bought.
  const after = applyRefund(new Map([[A, 20]]), { npub: A, amount: 100 });
  assert.equal(after.get(A), -80);
});

test('a negative balance cannot be spent from', () => {
  assert.throws(
    () => applyDebit(new Map([[A, -5]]), { npub: A, amount: 1 }),
    (e) => e.code === 'insufficient',
  );
});

test('amounts must be positive whole cubes', () => {
  for (const amount of [0, -1, 1.5, NaN, '10']) {
    assert.throws(
      () => applyCredit(new Map(), { npub: A, amount }),
      (e) => e.code === 'amount',
      `accepted ${amount}`,
    );
  }
});

test('a transfer to yourself is refused', () => {
  // Otherwise it is a no-op that still writes a journal row and still charges
  // whatever a transfer costs.
  assert.throws(
    () => applyTransfer(new Map([[A, 10]]), { from: A, to: A, amount: 1 }),
    (e) => e.code === 'self',
  );
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd wallet && node --test test/ledger.test.js`
Expected: FAIL — `Cannot find module '../src/ledger.js'`.

- [ ] **Step 3: Write minimal implementation**

Создать `wallet/src/ledger.js`:

```js
/// The arithmetic of the wallet, with nothing else in it.
///
/// No database, no HTTP, no clock. This is where a mistake costs the most —
/// money that appears or vanishes — so it is the part that runs entirely in a
/// unit test.
export class LedgerError extends Error {
  constructor(code, message) {
    super(message ?? code);
    this.code = code;
  }
}

/// Cubes are whole and positive. Floats are refused outright rather than
/// rounded: a rounded amount is a wrong amount somebody is charged.
function checkAmount(amount) {
  if (!Number.isSafeInteger(amount) || amount <= 0) {
    throw new LedgerError('amount', `bad amount ${amount}`);
  }
}

function checkNpub(npub) {
  if (!/^[0-9a-f]{64}$/.test(npub ?? '')) {
    throw new LedgerError('npub', 'npub must be 64 hex characters');
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

export function applyTransfer(rows, { from, to, amount }) {
  checkNpub(from);
  checkNpub(to);
  if (from === to) throw new LedgerError('self', 'cannot pay yourself');
  return applyCredit(applyDebit(rows, { npub: from, amount }), {
    npub: to,
    amount,
  });
}

/// The store took its money back. The balance may go below zero and that is
/// the point: it owes us until it is topped up again, and spending is blocked
/// meanwhile. What was already bought with those cubes stays bought — taking
/// it back afterwards is worse than carrying the loss.
export function applyRefund(rows, { npub, amount }) {
  checkNpub(npub);
  checkAmount(amount);
  const next = new Map(rows);
  next.set(npub, (next.get(npub) ?? 0) - amount);
  return next;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd wallet && node --test test/ledger.test.js`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add wallet/src/ledger.js wallet/test/ledger.test.js
git commit -m "The arithmetic of the wallet, where a mistake prints money"
```

---

### Task 2: Хранение, которое переживает перезапуск

**Files:**
- Create: `wallet/src/store.js`
- Create: `wallet/package.json`
- Test: `wallet/test/store.test.js`

**Interfaces:**
- Consumes: `applyCredit` и родственные из Task 1.
- Produces: `openStore(path)` → объект с
  `balanceOf(npub)`, `credit({npub, amount, txId, source})`,
  `debit({npub, amount, reason})`, `transfer({from, to, amount, transferId})`,
  `refund({npub, amount, txId})`, `journal(npub, limit)`, `close()`.
  Все операции — в одной транзакции SQLite.

- [ ] **Step 1: Create the package**

Создать `wallet/package.json`:

```json
{
  "name": "cubechat-wallet",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "description": "The cubes ledger: buys from a store receipt, spends in-app.",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js",
    "test": "node --test"
  },
  "engines": { "node": ">=20" },
  "dependencies": {
    "@noble/curves": "^1.6.0",
    "@noble/hashes": "^1.5.0",
    "better-sqlite3": "^11.3.0"
  }
}
```

Run: `cd wallet && npm install`

- [ ] **Step 2: Write the failing test**

Создать `wallet/test/store.test.js`:

```js
import assert from 'node:assert/strict';
import test from 'node:test';
import { openStore } from '../src/store.js';

const A = 'a'.repeat(64);
const B = 'b'.repeat(64);

function fresh() {
  return openStore(':memory:');
}

test('a credited balance is there after a reopen', () => {
  // The whole reason this is SQLite and not a Map: losing a row here is losing
  // somebody's money.
  const file = `${process.env.TEMP ?? '/tmp'}/wallet-${Date.now()}.db`;
  let store = openStore(file);
  store.credit({ npub: A, amount: 100, txId: 'tx1', source: 'apple' });
  store.close();

  store = openStore(file);
  assert.equal(store.balanceOf(A), 100);
  store.close();
});

test('the same store transaction credits exactly once', () => {
  // Mobile networks lose replies, so the app will send the same receipt again.
  const store = fresh();
  store.credit({ npub: A, amount: 100, txId: 'tx1', source: 'apple' });
  store.credit({ npub: A, amount: 100, txId: 'tx1', source: 'apple' });
  assert.equal(store.balanceOf(A), 100);
  store.close();
});

test('a failed transfer leaves both balances untouched', () => {
  const store = fresh();
  store.credit({ npub: A, amount: 10, txId: 'tx1', source: 'apple' });
  assert.throws(() =>
    store.transfer({ from: A, to: B, amount: 50, transferId: 't1' }));
  assert.equal(store.balanceOf(A), 10);
  assert.equal(store.balanceOf(B), 0);
  store.close();
});

test('a transfer is idempotent by its id', () => {
  const store = fresh();
  store.credit({ npub: A, amount: 10, txId: 'tx1', source: 'apple' });
  store.transfer({ from: A, to: B, amount: 4, transferId: 't1' });
  store.transfer({ from: A, to: B, amount: 4, transferId: 't1' });
  assert.equal(store.balanceOf(A), 6);
  assert.equal(store.balanceOf(B), 4);
  store.close();
});

test('an unknown account has a balance of zero, not an error', () => {
  const store = fresh();
  assert.equal(store.balanceOf(B), 0);
  store.close();
});

test('the journal records who, whom and how much', () => {
  const store = fresh();
  store.credit({ npub: A, amount: 10, txId: 'tx1', source: 'apple' });
  store.transfer({ from: A, to: B, amount: 4, transferId: 't1' });
  const rows = store.journal(A, 10);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].kind, 'transfer');
  store.close();
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd wallet && node --test test/store.test.js`
Expected: FAIL — `Cannot find module '../src/store.js'`.

- [ ] **Step 4: Write the store**

Создать `wallet/src/store.js`. Схема:

```sql
CREATE TABLE IF NOT EXISTS balances (
  npub TEXT PRIMARY KEY,
  cubes INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS journal (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at INTEGER NOT NULL,
  kind TEXT NOT NULL,
  from_npub TEXT,
  to_npub TEXT,
  amount INTEGER NOT NULL,
  ref TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS journal_ref ON journal(kind, ref)
  WHERE ref IS NOT NULL;
```

Требования к реализации:

- `PRAGMA journal_mode = WAL` и `PRAGMA synchronous = FULL`. Это деньги: потеря
  последней записи при выключении питания недопустима, и скорость здесь не
  важна — операций единицы в секунду.
- Каждая операция — `db.transaction(...)`, чтобы баланс и журнал менялись
  вместе или никак.
- Идемпотентность — через уникальный индекс на `(kind, ref)`: повтор ловится
  как нарушение ограничения и отвечает успехом, **не** начисляя второй раз.
- Арифметика вызывается из `ledger.js`, а не переписывается в SQL: правила про
  отрицательный баланс и про целые числа должны быть в одном месте.

- [ ] **Step 5: Run test to verify it passes**

Run: `cd wallet && node --test test/store.test.js`
Expected: PASS, 6 tests.

- [ ] **Step 6: Commit**

```bash
git add wallet/package.json wallet/package-lock.json wallet/src/store.js wallet/test/store.test.js
git commit -m "Keep the ledger where a power cut cannot take it"
```

---

### Task 3: Доказательство владения ключом и эндпоинты

**Files:**
- Create: `wallet/src/index.js`
- Test: `wallet/test/http.test.js`

**Interfaces:**
- Consumes: `openStore` из Task 2.
- Produces: экспортируемый `server` (как в `push/src/index.js`, чтобы тест мог
  его слушать на случайном порту) и эндпоинты:
  `POST /balance`, `POST /transfer`, `GET /health`.

- [ ] **Step 1: Write the failing test**

Создать `wallet/test/http.test.js`, скопировав помощники `signed()` и `post()`
из `push/test/register_replay.test.js` — они дают подписанное событие и
одноразовый сервер на случайном порту.

```js
test('a balance request must be signed by the key it asks about', async () => {
  // Without this the wallet is an oracle for "how much does this npub have",
  // answerable by anybody who knows a public key.
  const { status } = await post('/balance', { npub: 'a'.repeat(64) });
  assert.equal(status, 401);
});

test('a signed request gets its own balance', async () => {
  const event = signed({ tags: [['op', 'balance']] });
  const { status, body } = await post('/balance', { event });
  assert.equal(status, 200);
  assert.equal(body.cubes, 0);
});

test('an event signed by somebody else is refused', async () => {
  const event = signed({ tags: [['op', 'balance']] });
  event.pubkey = 'b'.repeat(64);
  const { status } = await post('/balance', { event });
  assert.equal(status, 401);
});

test('a stale event is refused', async () => {
  // A signed request is a bearer token until it expires; without a window an
  // overheard one works forever.
  const event = signed({ tags: [['op', 'balance']] });
  event.created_at = Math.floor(Date.now() / 1000) - 3600;
  const { status } = await post('/balance', { event });
  assert.equal(status, 401);
});

test('a transfer moves cubes between two keys', async () => {
  const payer = '02'.repeat(32);
  const payerPub = Buffer.from(schnorr.getPublicKey(payer)).toString('hex');
  const payee = 'c'.repeat(64);
  store.credit({ npub: payerPub, amount: 10, txId: 'tx1', source: 'apple' });

  const event = signed({ tags: [['op', 'transfer'], ['to', payee],
    ['amount', '4'], ['id', 't1']] });
  const { status } = await post('/transfer', { event });

  assert.equal(status, 200);
  assert.equal(store.balanceOf(payerPub), 6);
  assert.equal(store.balanceOf(payee), 4);
});

test('a transfer signed by the recipient does not pull funds', async () => {
  // The signature says who is *spending*. Reading the payer from the body
  // instead would make this endpoint a way to empty anybody's balance.
  const thief = '03'.repeat(32);
  const thiefPub = Buffer.from(schnorr.getPublicKey(thief)).toString('hex');
  const victim = 'd'.repeat(64);
  store.credit({ npub: victim, amount: 100, txId: 'tx2', source: 'apple' });

  const event = signed({ key: thief, tags: [['op', 'transfer'],
    ['to', thiefPub], ['amount', '50'], ['id', 't2'], ['from', victim]] });
  const { status } = await post('/transfer', { event });

  assert.equal(status, 400);
  assert.equal(store.balanceOf(victim), 100);
  assert.equal(store.balanceOf(thiefPub), 0);
});
```

`signed()` из `push/test/register_replay.test.js` подписывает фиксированным
ключом — здесь нужен параметр `key`, чтобы второй тест мог подписать чужим.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd wallet && node --test test/http.test.js`
Expected: FAIL — модуля нет.

- [ ] **Step 3: Write the service**

Создать `wallet/src/index.js`. Скопировать `verifyEvent`, `serializeForId` и
разбор тегов из `push/src/index.js` — **скопировать, а не импортировать через
каталог**: два сервиса деплоятся отдельно, и общий модуль между ними означает,
что выкладка кошелька может уронить доорбелл.

Правила авторизации:

- Событие обязано проходить `verifyEvent`.
- `created_at` — в пределах 120 секунд от now. Иначе подписанный запрос
  работает вечно.
- Действие берётся из тега `op`, потому что теги покрыты подписью.
- `npub` всегда `event.pubkey`; из тела он не читается никогда.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd wallet && node --test`
Expected: PASS — все файлы тестов.

- [ ] **Step 5: Commit**

```bash
git add wallet/src/index.js wallet/test/http.test.js
git commit -m "Prove the key, then answer - the wallet never trusts a body"
```

---

### Task 4: Чек стора

**Files:**
- Create: `wallet/src/receipts.js`
- Modify: `wallet/src/index.js`
- Test: `wallet/test/receipts.test.js`

**Interfaces:**
- Produces: `verifyPurchase({platform, token, productId}, deps)` →
  `{txId, cubes}` или `null`; `deps` содержит `fetch`, чтобы тест подставлял
  ответы Apple и Google без сети.
  Плюс `POST /credit` в сервисе.

- [ ] **Step 1: Write the failing test**

Проверяются четыре вещи, каждая — способ получить кубики даром:

- ответ стора «не куплено» не зачисляет ничего;
- неизвестный `productId` не зачисляет ничего, даже если стор сказал «куплено»;
- количество кубиков берётся из **нашей** таблицы товаров, а не из тела
  запроса;
- сетевой сбой при проверке — это отказ, а не зачисление.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd wallet && node --test test/receipts.test.js`

- [ ] **Step 3: Implement**

Таблица товаров в коде: `cubes.100` → 100, `cubes.500` → 500,
`cubes.1200` → 1200. Apple — `verifyReceipt`/App Store Server API, Google —
`purchases.products.get`. Обе проверки server-to-server, с ключами из
переменных окружения, никогда из репозитория.

- [ ] **Step 4: Run the whole suite**

Run: `cd wallet && node --test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add wallet/src/receipts.js wallet/src/index.js wallet/test/receipts.test.js
git commit -m "Believe the store, not the phone, about what was bought"
```

---

## Проверка перед сдачей

- [ ] `cd wallet && node --test` — зелёный
- [ ] Ни один тест не ходит в сеть: Apple и Google подставлены через `deps`
- [ ] Сумма балансов до и после серии переводов равна (тест в Task 1)
- [ ] В `git diff` нет ни одного ключа, токена и пароля
- [ ] `push/` не изменён ни одной строкой

## Вне объёма

Выкладка на дроплет, unit systemd и фрагмент Caddy — следующим планом, вместе с
первым эндпоинтом, которым пользуется приложение. Экран кубиков, покупка в
приложении, траты и переводы между людьми — планы 2–5 по спеке. Уведомления о
возвратах от Apple и Google — отдельно, сразу после выкладки: до неё их некуда
принимать.
