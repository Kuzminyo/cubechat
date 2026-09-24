# Moderation for App Store 1.2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pass App Review guideline 1.2: a terms gate, one-tap report (report + block + remove), a local profanity filter for strangers and channels, hide-for-me, in-app contact, and a moderation back end — reports to a Telegram bot with Ban/Dismiss buttons and a signed global ban list every phone applies.

**Architecture:** The push server (`push/src/index.js`, Node ≥ 20, no framework) gains three pure, exported handlers in the `handleTurn` style — `handleReport`, the Telegram notifier/poller, `bannedList` — wired into the existing `createServer`. The app gains `lib/features/moderation/` (data: terms, reports queue/client, ban list, filter settings; domain: report payload, profanity normaliser; presentation: terms gate, report sheet, about screen) and small additive hooks in the message bubble menu, contact profile, channel info, message preview and the inbound path.

**Tech Stack:** Flutter/Riverpod Notifiers, Hive encrypted settings box, `cryptography` (Ed25519 verify), the in-repo `Secp256k1NostrSigner`; Node `node:test`, `@noble/curves` (already a dependency), `node:crypto` Ed25519, global `fetch` for Telegram Bot API.

**Spec:** `docs/superpowers/specs/2026-09-24-moderation-ugc-design.md` (Russian; authority).

## Global Constraints

- Edit source with Edit/Write only (a hook blocks shell rewrites; shells mangle Cyrillic). Strict analyzer; 0 errors/warnings (grep both `-` and `•`).
- Every string in both `lib/l10n/app_en.arb` and `lib/l10n/app_uk.arb`, then `flutter gen-l10n`, commit generated files.
- The main checkout `D:/projects/cubechat` holds someone else's uncommitted app-icon work (ios/Runner/Info.plist, AndroidManifest.xml, MainActivity.kt, AppDelegate.swift, theme_controller.dart, cube_logo.dart, icon PNGs/appiconsets, tool/build_sticker_assets.py, deleted design-previews). Never stage, revert or reformat those; commit with explicit `git add <paths>` only. If a task must touch one of those files, STOP and report instead.
- `MessagingService` changes additive only. Load `wire-protocol` before touching `lib/core/transport/**`.
- Server: `cd push && node --test` must pass; bump `VERSION` in `push/src/index.js` in the last server task.
- Exact values: terms version `1`; report `note` ≤ 500 chars, message `text` ≤ 4000 chars, Telegram excerpt ≤ 1000 chars; report freshness 600 s past / 60 s future; rate limits 10/hour per reporter key and 200/hour total → 429; report queue retry up to 7 days; ban list refresh every 6 h and at start; support email `cubechatble@gmail.com`; report kind reuses `24242` with tag `['action','report']` (as `/turn` uses `['action','turn']`).
- Report `reason` ∈ `spam | abuse | violence | sexual | other`; `context` ∈ `direct | channel | airdrop | general`; message `kind` ∈ `text | photo | video | voice | file | sticker | other`.
- Commit subjects are a sentence about the effect; last line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Do not bump the app version or build.

## File map

| File | Responsibility |
|---|---|
| `push/src/index.js` | `handleReport`, `createTelegram`, `bannedList`, `/report`, `/banned`, 403 for banned on `/register`/`/turn` |
| `push/tool/gen_ban_key.mjs` | prints a fresh Ed25519 key pair (private PKCS8 base64 for env, public raw hex for the app) |
| `push/test/report.test.js`, `telegram.test.js`, `banned.test.js` | server tests |
| `push/deploy/README.md` | bot + env setup steps |
| `lib/features/moderation/domain/report.dart` | `ModerationReport` payload + validation |
| `lib/features/moderation/domain/profanity.dart` | normaliser + word list + `containsProfanity` |
| `lib/features/moderation/data/terms_controller.dart` | accepted terms version |
| `lib/features/moderation/data/report_client.dart` | sign + POST + persistent queue |
| `lib/features/moderation/data/ban_list_controller.dart` | fetch/verify/persist `/banned`, `isBanned` |
| `lib/features/moderation/data/filter_settings.dart` | "offensive-content filter" toggle (default on) |
| `lib/features/moderation/presentation/terms_gate.dart` | full-screen gate |
| `lib/features/moderation/presentation/report_sheet.dart` | reason sheet + one-tap report/block/remove |
| `lib/features/moderation/presentation/about_screen.dart` | contact, general report, links |

---

## Part S — server

### Task S1: `POST /report` stores a signed, fresh, bounded report

**Files:** Modify `push/src/index.js`; Create `push/test/report.test.js`.

**Interfaces — Produces:**
```js
export function handleReport(event, {
  nowSeconds = Math.floor(Date.now() / 1000),
  limiter,            // { allow(pubkey, nowSeconds): boolean }
  store,              // { append(report): Promise<void> }  (report object below)
  notify = () => {},  // (report) => void, fire-and-forget
} = {}) // → Promise<{ status, body }>
export function createRateLimiter({ perKey = 10, total = 200, windowSeconds = 3600 } = {})
export function createReportStore(path = process.env.REPORTS_PATH || './reports.jsonl')
// stored report: { id: <16 hex>, at: nowSeconds, reporter: event.pubkey, status: 'open',
//   reason, note?, target?, targetNpub?, context, channelId?, message? }
```

- [ ] **Step 1: Failing tests** in `push/test/report.test.js` (copy the `signed()` helper from `turn_endpoint.test.js`, with `tags: [['action','report']]` and `content: JSON.stringify(payload)`):
  1. a valid report → 200 `{ok:true, id}`, `store.append` called once with `status:'open'`, `reporter` = event pubkey, `notify` called once;
  2. bad signature, wrong kind, missing `['action','report']` tag, a `/turn`-tagged event → 401 `signature`;
  3. `created_at` 601 s old or 61 s in the future → 401 `stale`;
  4. invalid content: not JSON; unknown `reason`; unknown `context`; `note` 501 chars; `message.text` 4001 chars; `target` not 64 hex; `context:'direct'` without `target` → 400 `payload`;
  5. `context:'general'` without `target` → 200;
  6. limiter: 11th report from one key within an hour → 429; 201st overall → 429; a key's quota frees after an hour;
  7. the HTTP route: `POST /report` through `server` returns the handler's status (mirror the server test in `turn_endpoint.test.js`), with the store injected via a module-level setter or env `REPORTS_PATH` pointing at a temp file.
- [ ] **Step 2:** `cd push && node --test test/report.test.js` → FAIL.
- [ ] **Step 3: Implement.** Validation function `parseReportPayload(content)` returning the payload or `null`. `createReportStore` appends `JSON.stringify(report) + '\n'` with `appendFile`, and exposes `update(id, patch)` (rewrite the file through a temp + `rename`, like the token store at ~line 107) and `open()` listing open reports — S2 needs both. Route in `createServer`: `POST /report` → read body (existing `readBody`), `JSON.parse` (400 `body` on failure), `handleReport` with the module's limiter/store/notify, `cache-control: no-store`.
- [ ] **Step 4:** tests pass; `node --test` whole suite passes.
- [ ] **Step 5: Commit** — "The push server takes signed abuse reports and keeps them".

### Task S2: reports reach the owner's Telegram, with Ban / Dismiss

**Files:** Modify `push/src/index.js`; Create `push/test/telegram.test.js`.

**Interfaces — Produces:**
```js
export function createTelegram({ token, ownerChatId, fetchImpl = fetch, store, bans, log = console.log })
// → { notify(report): void, pollOnce(): Promise<void>, start(): void, stop(): void }
export function reportMessage(report) // → { text, reply_markup }
```
`bans` is S3's `{ ban(report): Promise<void>, unban(key): Promise<boolean> }` — in S2 tests pass a fake.

- [ ] **Step 1: Failing tests** with a fake `fetchImpl` recording calls to `https://api.telegram.org/bot<token>/<method>`:
  1. `notify(report)` posts `sendMessage` to `ownerChatId` with text containing the reason label, context, the first 8 hex of target and reporter, the message text cut to 1000 chars, and `reply_markup.inline_keyboard` = `[[{text:'Забанити',callback_data:'ban:<id>'},{text:'Відхилити',callback_data:'dismiss:<id>'}]]`;
  2. a failing `sendMessage` (fetch rejects / `ok:false`) is retried with backoff (1 s, 5 s, 30 s, then gives up with a log line) — use injected timers or a `retryDelays` option; the report stays stored;
  3. `pollOnce()` calls `getUpdates` with `offset` = last update id + 1 and `timeout` ≥ 25; a `callback_query` `ban:<id>` from `ownerChatId` → `bans.ban(report)`, `store.update(id,{status:'banned'})`, `answerCallbackQuery`, `editMessageText` appending "✅ Забанено";
  4. `dismiss:<id>` → status `dismissed`, "✖️ Відхилено";
  5. a callback or message from another chat id → ignored (no store/ban calls);
  6. text `/reports` from the owner → `sendMessage` listing open reports (id, reason, target short), or "Відкритих скарг немає";
  7. `/unban <hex>` → `bans.unban(hex)` and a confirmation;
  8. missing `token` or `ownerChatId` → `notify` and `start` are no-ops that log once "telegram not configured".
- [ ] **Step 2:** FAIL.
- [ ] **Step 3: Implement.** `start()` runs `pollOnce` in a loop (`timeout: 30` long poll, on error wait 5 s), guarded against double start; `stop()` ends it (tests and shutdown). Wire into the server: env `TELEGRAM_BOT_TOKEN`, `TELEGRAM_OWNER_CHAT_ID`; `handleReport`'s `notify` → `telegram.notify`; call `telegram.start()` where the server starts listening (not on import, so tests importing `server` don't poll — follow how the relay sockets are started).
- [ ] **Step 4:** pass; whole suite.
- [ ] **Step 5: Commit** — "Every report pings the owner in Telegram, with Ban and Dismiss on it".

### Task S3: a signed global ban list, enforced on the server too

**Files:** Modify `push/src/index.js`, `push/deploy/README.md`; Create `push/tool/gen_ban_key.mjs`, `push/test/banned.test.js`.

**Interfaces — Produces:**
```js
export function createBans({ path = process.env.BANNED_PATH || './banned.json', signingKeyPkcs8B64 = process.env.BAN_SIGNING_KEY, nowSeconds })
// → { ban(report), unban(key): Promise<boolean>, isBannedNpub(hex): boolean, list(): signedBody }
// signedBody: { v: 1, updatedAt, identities: [hex], npubs: [hex], fingerprints: [hex], sig }
export function canonicalBanBody(body) // JSON.stringify of {v, updatedAt, identities, npubs, fingerprints} with sorted arrays, no sig
```
`ban(report)`: adds `report.target` to `identities` when `context !== 'channel'`, to `fingerprints` when `context === 'channel'` (a channel author is known by signing fingerprint, not identity key — see `Message.authorId`), and `report.targetNpub` to `npubs` when present. `sig` = Ed25519 over `canonicalBanBody` UTF-8, hex.

- [ ] **Step 1: Failing tests:** `ban` then `list()` → contains the key, `sig` verifies with the public key (`crypto.verify(null, …)`), and fails after any field is altered; `unban` removes it; persisted across a new `createBans` on the same file; `GET /banned` returns the signed body with `cache-control: public, max-age=300`; `/register` and `/turn` return 403 `banned` for an event whose `pubkey` is a banned npub (sign with the helper and ban that npub first); no signing key configured → `/banned` 503 `unconfigured`.
- [ ] **Step 2:** FAIL.
- [ ] **Step 3: Implement**, plus `push/tool/gen_ban_key.mjs`: `crypto.generateKeyPairSync('ed25519')`; print `BAN_SIGNING_KEY=<pkcs8 der base64>` and `APP_PUBLIC_KEY_HEX=<raw 32-byte public key hex>` (raw = last 32 bytes of the SPKI DER). Deploy README: a "Moderation" section — create a bot with @BotFather (`/newbot`), send it any message, get your chat id from `https://api.telegram.org/bot<TOKEN>/getUpdates` (`message.chat.id`), run `node tool/gen_ban_key.mjs` once, add the three env vars to the systemd unit's environment file, restart, check `/health` and `GET /banned`. Bump `VERSION` to `'2026-09-24-moderation'`.
- [ ] **Step 4:** pass; whole suite.
- [ ] **Step 5:** Run `node push/tool/gen_ban_key.mjs` once; put the PUBLIC key hex into Task A6's constant (write it into `.superpowers/sdd/<plan>/ban-public-key.txt` for the A6 implementer) and the PRIVATE line into `.superpowers/sdd/<plan>/ban-signing-key.secret` (git-ignored folder; never committed). Commit the code — "Bans are a signed list the server publishes and enforces".

---

## Part A — app

### Task A1: terms before anything else

**Files:** Create `lib/features/moderation/data/terms_controller.dart`, `lib/features/moderation/presentation/terms_gate.dart`, `test/terms_gate_test.dart`; Modify `lib/app.dart` (mount beside `AppLockGate` ~line 677), `lib/core/identity/wipe_service.dart`, arb files.

**Interfaces — Produces:** `const int currentTermsVersion = 1;` `termsControllerProvider` (Notifier<int> accepted version, `loaded`, `accept()`, `reset()`), storage key `'moderation.termsAccepted'` in the encrypted settings box (pattern: `lib/features/airdrop/data/airdrop_lane_controller.dart`, including its `_touched` guard against a load race).

- [ ] **Step 1: Failing widget tests:** with accepted < 1 the gate covers the app (the child is not hit-testable, back does nothing), shows the rules text and "Приймаю"; tapping it stores 1 and reveals the child; with accepted == 1 the child shows immediately; after `reset()` the gate returns. While `loaded` hasn't completed, show neither child nor gate content (blank background) — no flash of the app.
- [ ] **Step 2:** FAIL. **Step 3:** implement. Strings (en / uk):
  - `termsTitle`: "cubechat rules" / "Правила cubechat"
  - `termsBody`: "cubechat has zero tolerance for objectionable content and abusive users. By continuing you agree not to send harassment, threats, sexual content involving minors, spam or anything illegal. Anyone can report a message or a person; reports reach the developer and are acted on within 24 hours, and offenders are banned." / "cubechat не терпить образливого вмісту та тих, хто ним зловживає. Продовжуючи, ви погоджуєтеся не надсилати цькування, погрози, сексуальний вміст за участю неповнолітніх, спам і нічого незаконного. Будь-хто може поскаржитися на повідомлення чи людину; скарги надходять розробнику й розглядаються протягом 24 годин, порушників блокують."
  - `termsReadFull`: "Read the full terms" / "Повні умови" → `url_launcher` to `https://cubechat.tech/terms`
  - `termsAccept`: "I agree" / "Приймаю"
  Wipe: `await ref.read(termsControllerProvider.notifier).reset();`.
- [ ] **Step 4:** `flutter test test/terms_gate_test.dart` + `flutter test test/hive_wipe_test.dart`. **Step 5: Commit** — "Nobody gets past the first screen without agreeing to the rules".

### Task A2: a report is signed, sent, and never lost

**Files:** Create `lib/features/moderation/domain/report.dart`, `lib/features/moderation/data/report_client.dart`, `test/report_client_test.dart`.

**Interfaces — Produces:**
```dart
enum ReportReason { spam, abuse, violence, sexual, other }
enum ReportContext { direct, channel, airdrop, general }
enum ReportedKind { text, photo, video, voice, file, sticker, other }
class ModerationReport { ModerationReport({required reason, note, target, targetNpub, required context, channelId, messageText, messageKind, messageSentAt}); Map<String,Object?> toJson(); static ModerationReport? fromJson(Map); }
// toJson enforces the spec's caps (note ≤ 500, text ≤ 4000 — truncated, never thrown)
final reportClientProvider = Provider<ReportClient>(...);
class ReportClient { Future<bool> send(ModerationReport r); Future<void> flush(); }
// send: queue first (persist), then try to POST; true when accepted now.
```
Signing: exactly the `/turn` request in `lib/features/call/data/turn_credentials_controller.dart` (`Secp256k1NostrSigner.deriveFromSeed(identity.signPrivateKey)`, kind 24242), with tags `[['action','report']]` and `content: jsonEncode(report.toJson())`. Endpoints: `https://push.cubechat.tech/report`, then `https://209-38-225-225.sslip.io/report` (same fallback as `PushRegistration.endpoints`). Queue: encrypted Hive box entry `'moderation.reportQueue'` (list of `{queuedAt, payload}`), dropped after 7 days; `flush()` on app start and when connectivity returns (`connectivity_plus` is already a dependency). HTTP injectable for tests (a `Future<int> Function(Uri, String body)` post function).

- [ ] **Step 1: Failing tests:** payload JSON shape and truncation; `send` persists before posting; 200 → dequeued, `true`; network error / 5xx → stays queued, `false`; 400/401 → dropped (a bad payload never retries forever) and logged; second endpoint tried when the first throws; entries older than 7 days dropped on `flush`; the signed event has kind 24242, tag `['action','report']`, and its content decodes to the payload.
- [ ] **Step 2–4:** FAIL → implement → `flutter test test/report_client_test.dart`. **Step 5: Commit** — "A report is signed by the phone and waits in a queue until the server has it".

### Task A3: "Report" — one tap sends, blocks and removes

**Files:** Create `lib/features/moderation/presentation/report_sheet.dart`, `test/report_sheet_test.dart`; Modify `lib/features/chat/presentation/widgets/message_bubble.dart` (menu ids near `'airdrop'`/`'delete'` ~lines 859–1016), `lib/features/peers/presentation/contact_profile_screen.dart`, `lib/features/channels/presentation/channel_info_screen.dart`, arb files.

**Interfaces — Produces:** `Future<bool> showReportSheet(BuildContext, WidgetRef, {required ReportContext context, String? targetHex, String? targetNpub, String? channelId, Message? message, String? chatId})`.

Behaviour on "Надіслати" (spec §2):
1. `reportClient.send(...)`;
2. block: `direct`/`airdrop` → `knownPeersControllerProvider.notifier.setBlocked(targetHex, true)`; `channel` with a message → no identity to block (authors are fingerprints) — hide the message and add the author fingerprint to a local hidden-authors set that the channel view filters (store beside the ban list in A6 as `locallyHiddenFingerprints`; if A6 isn't there yet, this task creates `lib/features/moderation/data/hidden_authors.dart` with a simple persisted set and A6 reuses it); `channel` without a message (report on the channel) → leave/hide the channel via the existing leave action in `channel_info_screen.dart`;
3. remove: with a message → `messagesControllerProvider.notifier.deleteLocal(chatId, message.id)`;
4. toast `reportSent`.

Menu item "Поскаржитися" (`Icons.flag_outlined`) on messages that are not `isMine`, in direct chats and channels; on the contact profile; in channel info. Reasons sheet: five `ReportReason`s, "інше" reveals a 500-char text field. Strings (en / uk): `reportAction` Report / Поскаржитися; `reportTitle` "What's wrong?" / "Що не так?"; `reportReasonSpam` Spam / Спам; `reportReasonAbuse` "Abuse or harassment" / "Образа або цькування"; `reportReasonViolence` Violence / Насильство; `reportReasonSexual` "Sexual content" / "Сексуальний вміст"; `reportReasonOther` Other / Інше; `reportNoteHint` "Describe (optional)" / "Опишіть (необов'язково)"; `reportSend` Send / Надіслати; `reportSent` "Report sent. We review reports within 24 hours." / "Скаргу надіслано. Ми розглянемо її протягом 24 годин."; `reportBlockedToo` "They're blocked for you." / "Для вас цю людину заблоковано.".

Mapping `Message` → report: `messageText` = `message.text` for text; `messageKind` from `MessageKind` (`image`→photo unless its mime/flags say video; `audio`→voice; `file`→file; stickers are text with `Message.stickerMarker`→sticker; `poll`→other); `messageSentAt` = `sentAt`.

- [ ] **Steps:** failing widget tests (sheet sends the right payload per context; direct report blocks and deletes locally; channel message report hides the message and the author; channel report leaves; the menu item is absent on own messages) → implement → tests → commit "One tap reports a message or a person, blocks them and takes it off the screen".

### Task A4: "Hide" — remove someone else's message for me only

**Files:** Modify `message_bubble.dart`, arb; Test `test/message_hide_test.dart`.

Menu item "Приховати" (`Icons.visibility_off_outlined`) on messages that are not `isMine` → `deleteLocal(chatId, id)` at once, then an undo toast (reuse `lib/core/widgets/undo_toast.dart`; undo re-inserts via whatever `deleteLocal`'s counterpart is — if none exists, keep the removed `Message` in memory for the toast's lifetime and restore through `messagesControllerProvider` by re-adding it; say which in the report). Strings: `messageHide` Hide / Приховати; `messageHidden` "Hidden for you" / "Приховано для вас"; undo reuses the existing undo string.

- [ ] Steps: failing test → implement → test → commit "Anyone else's message can be taken off your screen with one tap".

### Task A5: the filter for strangers and channels

**Files:** Create `lib/features/moderation/domain/profanity.dart`, `lib/features/moderation/data/filter_settings.dart`, `test/profanity_test.dart`, `test/filtered_bubble_test.dart`; Modify `message_bubble.dart` (collapsed state), `lib/features/chat/domain/message_preview.dart` (preview/notification text), the profile screen (toggle), arb.

**Interfaces — Produces:**
```dart
String normaliseForFilter(String s); // lower-case; ё→е, ї/і→и? NO — keep Ukrainian letters; map Latin look-alikes to Cyrillic (a→а, e→е, o→о, p→р, c→с, x→х, y→у, k→к, m→м, t→т, h→н, b→в) only inside words that already contain Cyrillic; collapse runs of 3+ same letters to 1; strip * . _ - between letters
bool containsProfanity(String text); // word-boundary match of normalised tokens against stems
final filterEnabledProvider = NotifierProvider<FilterSettings, bool>(...); // default true, key 'moderation.filterEnabled'
bool shouldFilter({required Message m, required bool isChannel, required bool fromContact, required bool enabled}) // !m.isMine && enabled && (isChannel || !fromContact) && containsProfanity(m.text)
```
Word list: a `const Set<String>` of stems in `profanity.dart` — roughly 40 Ukrainian/Russian obscenity stems (the хуй/пизд/ебл/ёб/бля/сук/мудак/гандон/підар/пидор/шлюх/курв/залуп families) and 30 English (fuck/shit/cunt/bitch/whore/slut/nigg/fagg/retard/…) plus slurs; match a token when it starts with a stem, except an explicit allow-list for innocent words sharing a stem (e.g. "скипидар", "потребля", "оскорбля", "страхуй", "команд", "document", "scunthorpe", "assess", "cocktail", "shitake"). Comment that the list is deliberately short and stem-based, and why (App Review asks for a filter, not a classifier).

UI: a filtered bubble renders a compact row "Приховано фільтром · Показати"; "Показати" reveals it for this view (state in the bubble, not persisted). Preview/notification for such a message: "Приховано фільтром". Profile toggle "Фільтр образливого вмісту" with hint "Ховає грубі слова від незнайомих і в каналах". Strings: `filteredMessage` "Hidden by the filter" / "Приховано фільтром"; `filteredShow` Show / Показати; `filterToggle` "Offensive-content filter" / "Фільтр образливого вмісту"; `filterToggleHint` "Hides rude words from strangers and in channels" / "Ховає грубі слова від незнайомих і в каналах".

- [ ] Steps: failing tests (normaliser cases incl. "х у й", "fuuuck", "f*ck", "хyй" with Latin y; allow-list words pass; contact message not filtered; stranger and channel filtered; toggle off disables; own messages never) → implement → tests → commit "Rude words from strangers and in channels fold away until you ask to see them".

### Task A6: the global ban list, applied everywhere

**Files:** Create `lib/features/moderation/data/ban_list_controller.dart`, `test/ban_list_test.dart`; Modify the inbound path in `lib/core/transport/messaging_service.dart` (additive: drop a frame whose sender identity is banned, as blocked peers are dropped — find where `isBlocked` is consulted and OR the ban in), channel post handling (drop posts whose author fingerprint is banned or locally hidden), the chats list (hide channels whose owner/admin fingerprint is banned), `AirDropController._onOffer` and `BumpController._onInbound` (ignore banned senders silently), and wherever the UI already hides blocked peers' content.

**Interfaces — Produces:** `banListProvider` (Notifier<BanList>) with `bool isBannedIdentity(String hex)`, `bool isBannedFingerprint(String hex)`; `const String banListPublicKeyHex = '<from .superpowers/sdd/<plan>/ban-public-key.txt>';` Fetch `https://push.cubechat.tech/banned` (sslip fallback) at start and every 6 h while foregrounded; verify Ed25519 over the canonical body (exact same canonicalisation as `canonicalBanBody` in S3: keys `v, updatedAt, identities, npubs, fingerprints` in that order, arrays sorted, `jsonEncode`); reject older `updatedAt` than the stored one; persist the last good list in the encrypted settings box `'moderation.banList'`.

- [ ] Steps: failing tests (a list signed with a test key verifies; tampered/unsigned rejected; older `updatedAt` ignored; persisted and reloaded; a banned identity's inbound message is dropped and existing messages hidden; banned fingerprint's channel posts hidden; AirDrop offer from a banned identity ignored) → implement → tests (include `test/airdrop_controller_test.dart`, `test/bump_controller_test.dart`) → commit "Anyone the developer bans disappears from every phone".

### Task A7: About — contact, general report, links

**Files:** Create `lib/features/moderation/presentation/about_screen.dart`, `test/about_screen_test.dart`; Modify the profile screen (entry row "Про застосунок"), router if it uses named routes (push with `Navigator` like other profile sub-screens), arb.

Content: app name + `appVersion` + `appBuildStamp`; "Написати розробнику" → `mailto:cubechatble@gmail.com` via `url_launcher`; "Повідомити про порушення" → `showReportSheet(context: ReportContext.general)`; "Умови використання" → `https://cubechat.tech/terms`; "Політика конфіденційності" → `https://cubechat.tech/privacy`. Strings: `aboutTitle` About / "Про застосунок"; `aboutContact` "Email the developer" / "Написати розробнику"; `aboutReport` "Report a violation" / "Повідомити про порушення"; `aboutTerms` "Terms of use" / "Умови використання"; `aboutPrivacy` "Privacy policy" / "Політика конфіденційності".

- [ ] Steps: failing test (rows present; tapping report opens the sheet with general context) → implement → test → commit "The app says how to reach the developer and report abuse".

### Task A8: legal texts, the reply to Apple, full check

**Files:** Modify `docs/legal/privacy-policy.en.md`, `.uk.md`, `terms.en.md`, `terms.uk.md`, `store-disclosures.md`; Create `docs/legal/app-review-reply-1.2.md`.

- Privacy (en/uk): section "Reports" — what a report contains (spec §3), that it's sent only when you tap Report, who sees it (the developer), retention (until decided + 90 days), the public ban list (keys only).
- Terms (en/uk): zero tolerance, what's prohibited (the A1 list), reporting, 24-hour review, bans.
- Store disclosures: "User Content — reports: linked to the user, not used for tracking".
- The reply to App Review (English): 18+ rating set; terms gate at first launch; report on every message/person/channel (one tap reports, blocks, removes); hide; block; filter for strangers and channels; reports reach the developer instantly and are acted on within 24 h; banning removes the user from every phone via a signed ban list; contact in Profile → About; E2E encryption means the server sees content only inside reports.
- Full `flutter analyze` and `flutter test --exclude-tags golden`, `cd push && node --test`; report counts. Commit — "Say in the policies how reports and bans work, and draft the reply to App Review".
