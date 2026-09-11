# Звонки, часть 2: сервер, медиа и кнопка — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** довести звонок до того, что два телефона с открытым приложением
действительно слышат друг друга, и поставить кнопку звонка в профиле контакта.

**Architecture:** на уже существующем дроплете поднимается coturn; пуш-сервер,
который там же и работает, получает один новый эндпоинт, выдающий
короткоживущий доступ к нему по той же подписи, что и регистрация токена. В
приложении появляется `flutter_webrtc`, контроллер `CallController`, который
владеет машиной состояний из части 1 и переводит её события в
`RTCPeerConnection`, экран звонка и кнопка в профиле контакта. Медиа по
умолчанию идёт только через TURN — `iceTransportPolicy: 'relay'`, — а прямое
соединение включается тумблером в настройках и никогда не подставляется само.

**Tech Stack:** Dart, Flutter 3.41.x, `flutter_webrtc` (проверено: резолвится с
текущим набором зависимостей, тянет только `webrtc_interface`), Node.js без
фреймворка на сервере, coturn, systemd, Caddy.

**Spec:** `docs/superpowers/specs/2026-09-10-calls-design.md`

**Предыдущий план:** `docs/superpowers/plans/2026-09-10-calls-wire-and-state-machine.md`
— его раздел «Что этот план оставил следующим» перечисляет пять находок,
которые закрываются здесь, в задаче 8.

## Что этот план даёт и чего не даёт

Даёт: звонок один на один между двумя телефонами, у которых приложение
открыто. Кнопку в профиле контакта. Экран звонка. Запись о звонке в переписке.

**Не даёт звонка в закрытое приложение.** CallKit, VoIP-пуш и служба
переднего плана на Android — это часть 3, и без них входящий звонок виден
только пока приложение на экране. Флаг `c` уже уходит на реле с части 1, но
сервер его пока не читает, и это здесь не меняется: читать его имеет смысл
только когда есть кому доложить о звонке.

Не даёт видео и групп — спека выносит их за первую версию.

## Global Constraints

- **Медиа по умолчанию идёт через свой TURN.** `iceTransportPolicy: 'relay'`.
  Если TURN недоступен, звонок падает с внятной причиной и **никогда** не
  переключается на прямое соединение сам: тихий откат раскрыл бы IP там, где
  человек выбрал его скрыть. Это единственное место в дизайне, где мы
  отказываем в услуге вместо того, чтобы «как-нибудь дозвониться».
- Прямое соединение — тумблер в настройках, по умолчанию выключен.
- Микрофон спрашивается до отправки приглашения, а не после.
- Звонок забирает аудиофокус безусловно. Тумблер паузы музыки для кружков на
  звонок не распространяется.
- `MessagingService` — работа только аддитивная.
- Анализатор строгий: `strict-casts`, `strict-inference`, `strict-raw-types`,
  `prefer_final_locals`, `require_trailing_commas`. Гейт CI —
  `grep -E '^[[:space:]]*(error|warning)[[:space:]]*[-•]'` по сохранённому логу.
- Комментарии объясняют почему и несут наблюдение, оправдавшее решение.
  По-английски.
- **Файлы с не-ASCII создавать и править только Write/Edit, никогда через
  шелл.** Хук блокирует переписывание исходников шеллом.
- Флаги на проводе не добавляются: часть 1 уже положила туда всё, что нужно.
  Если кажется, что нужен новый тип — сначала загрузить навык `wire-protocol`.
- Базы на момент старта: полный прогон 1554 passed / 2 skipped, анализатор 768
  issues и ноль по гейту.

## Про сервер, до первой команды

Дроплет `209.38.225.225`, там уже работают `cubechat-push.service`,
`cubechat-relay.service` (strfry) и Caddy. Порты 3478 и 5349 свободны, coturn
не установлен. Доступ по ключу настроен, пароль root вводить не нужно и
нельзя.

**`/etc/caddy/Caddyfile` не трогать** — там блоки пуш-сервера, и coturn идёт
мимо Caddy, своими портами.

---

## Фаза А — сервер

### Task 1: coturn на дроплете

**Files:**
- Create on the droplet: `/etc/turnserver.conf`
- Create in repo: `turn/README.md`, `turn/turnserver.conf.example`
- Modify: `push/.env.example` (добавить `TURN_SECRET`, `TURN_REALM`)

**Interfaces:**
- Consumes: ничего из кода приложения.
- Produces: работающий TURN на `turn.cubechat.tech` (или на IP, если записи
  DNS нет), порты 3478 UDP/TCP и 5349 TLS, диапазон ретрансляции
  49160–49200, аутентификация `use-auth-secret` с общим секретом. Секрет
  лежит в `/etc/turnserver.conf` и в `/etc/cubechat-push.env` и **никогда не
  попадает в репозиторий**.

- [ ] **Step 1: Проверить, что порты свободны и что мы вообще на той машине**

```bash
ssh -o BatchMode=yes root@209.38.225.225 "hostname; ss -lntup | grep -E ':(3478|5349)' || echo 'turn ports free'"
```

Expected: `app`, и `turn ports free`.

- [ ] **Step 2: Установить coturn**

```bash
ssh -o BatchMode=yes root@209.38.225.225 "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y coturn"
```

- [ ] **Step 3: Сгенерировать секрет и записать конфиг**

Секрет генерируется на сервере и обратно в сессию не читается целиком —
достаточно знать, что он есть.

```bash
ssh -o BatchMode=yes root@209.38.225.225 "openssl rand -hex 32 > /etc/turnserver.secret && chmod 600 /etc/turnserver.secret && echo 'secret written, length:' && wc -c < /etc/turnserver.secret"
```

Конфиг пишется через `tee` с here-doc, файл чисто ASCII:

```bash
ssh -o BatchMode=yes root@209.38.225.225 "SECRET=\$(cat /etc/turnserver.secret) && tee /etc/turnserver.conf > /dev/null <<EOF
listening-port=3478
tls-listening-port=5349
min-port=49160
max-port=49200
fingerprint
use-auth-secret
static-auth-secret=\$SECRET
realm=cubechat.tech
no-multicast-peers
no-cli
no-tlsv1
no-tlsv1_1
# Only relay for our own users, never as an open relay for the internet.
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
EOF
chmod 600 /etc/turnserver.conf && echo written"
```

Диапазоны `denied-peer-ip` — не украшение: без них любой, кто получил
короткоживущий доступ, может через наш сервер ходить в его же локальную сеть
и к соседним службам на том же дроплете.

- [ ] **Step 4: Открыть порты и запустить**

```bash
ssh -o BatchMode=yes root@209.38.225.225 "ufw allow 3478/udp && ufw allow 3478/tcp && ufw allow 5349/tcp && ufw allow 49160:49200/udp && sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn 2>/dev/null; systemctl enable --now coturn && systemctl is-active coturn"
```

Expected: `active`.

- [ ] **Step 5: Доказать, что он выдаёт адрес, а не просто слушает**

Слушающий порт ничего не доказывает. Проверка — реальное выделение адреса с
временным доступом, посчитанным по тому же правилу, что будет считать
пуш-сервер:

```bash
ssh -o BatchMode=yes root@209.38.225.225 "apt-get install -y -qq coturn-utils 2>/dev/null; SECRET=\$(cat /etc/turnserver.secret); USER=\$(( \$(date +%s) + 600 )); PASS=\$(echo -n \$USER | openssl dgst -binary -sha1 -hmac \$SECRET | base64); turnutils_uclient -u \$USER -w \$PASS -p 3478 -DgX -n 1 127.0.0.1 2>&1 | tail -5"
```

Expected: строки про успешное выделение (`allocate`), не `error`.

- [ ] **Step 6: Записать в репозиторий, что на сервере сделано**

Создать `turn/README.md`: что установлено, какие порты, где лежит секрет,
почему `denied-peer-ip` обязательны, и как повторить установку с нуля. Создать
`turn/turnserver.conf.example` — копию конфига с `static-auth-secret=REPLACE_ME`.
Добавить в `push/.env.example` строки `TURN_SECRET=` и
`TURN_REALM=cubechat.tech` с комментарием, что секрет тот же, что в
`/etc/turnserver.conf`, и что расхождение проявится только в момент звонка.

**В репозиторий секрет не попадает.** Если он оказался в diff — остановиться и
доложить.

- [ ] **Step 7: Коммит**

```bash
git add turn/ push/.env.example
git commit -m "Stand up a TURN server on the droplet we already run"
```

---

### Task 2: эндпоинт, выдающий доступ к TURN

**Files:**
- Modify: `push/src/index.js` (роутер около строки 917, рядом с `/health` и `/register`)
- Create: `push/test/turn_credentials.test.js`
- Modify: `push/package.json` (скрипт `test`, если его нет)

**Interfaces:**
- Consumes: `verifyEvent`, `REGISTER_KIND`, `short` — уже в `index.js`.
- Produces: `POST /turn`, принимающий подписанное событие того же вида, что и
  `/register` (kind 24242, свежее `REGISTER_MAX_AGE_SECONDS`), и отвечающий:

```json
{
  "ok": true,
  "username": "<unix-expiry>",
  "password": "<base64 hmac-sha1>",
  "ttl": 600,
  "urls": ["turn:turn.cubechat.tech:3478?transport=udp",
           "turn:turn.cubechat.tech:3478?transport=tcp",
           "turns:turn.cubechat.tech:5349?transport=tcp"]
}
```

- [ ] **Step 1: Написать падающий тест**

Создать `push/test/turn_credentials.test.js` на встроенном `node:test`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { turnCredentials } from '../src/index.js';

test('the username is the moment the credential dies', () => {
  const now = 1789000000;
  const c = turnCredentials({ secret: 's3cret', ttlSeconds: 600, nowSeconds: now });
  assert.equal(c.username, String(now + 600));
  assert.equal(c.ttl, 600);
});

test('the password is an hmac of the username under the shared secret', () => {
  const now = 1789000000;
  const c = turnCredentials({ secret: 's3cret', ttlSeconds: 600, nowSeconds: now });
  const expected = createHmac('sha1', 's3cret').update(c.username).digest('base64');
  assert.equal(c.password, expected);
});

test('two calls a second apart do not hand out the same password', () => {
  const a = turnCredentials({ secret: 's', ttlSeconds: 600, nowSeconds: 1 });
  const b = turnCredentials({ secret: 's', ttlSeconds: 600, nowSeconds: 2 });
  assert.notEqual(a.password, b.password);
});

test('a missing secret is refused rather than handing out a blank password', () => {
  // A blank secret still produces a valid-looking hmac, and coturn would
  // refuse it at call time — which surfaces as "the call does not connect"
  // with nothing in any log pointing here.
  assert.throws(() => turnCredentials({ secret: '', ttlSeconds: 600, nowSeconds: 1 }));
});
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `cd push && node --test test/`
Expected: FAIL — `turnCredentials` не экспортируется.

- [ ] **Step 3: Реализовать и экспортировать `turnCredentials`**

В `push/src/index.js`, рядом с прочими чистыми помощниками:

```js
/// Short-lived TURN access, by coturn's own REST convention.
///
/// The username IS the expiry, as a unix timestamp, and the password is an
/// HMAC of it under the secret coturn holds. That is the whole protocol:
/// coturn recomputes the HMAC and compares, so nothing has to be stored on
/// either side and a leaked credential dies on its own.
///
/// The secret cannot travel to the app — an APK is not a place to keep one —
/// which is the reason this endpoint exists at all rather than the app
/// deriving its own.
export function turnCredentials({ secret, ttlSeconds, nowSeconds }) {
  if (!secret) {
    // A blank secret yields a valid-looking credential that coturn rejects at
    // call time, and the failure then looks like a broken call rather than a
    // misconfigured server.
    throw new Error('TURN_SECRET is not set');
  }
  const username = String(nowSeconds + ttlSeconds);
  const password = createHmac('sha1', secret).update(username).digest('base64');
  return { username, password, ttl: ttlSeconds };
}
```

Добавить `import { createHmac } from 'node:crypto';` если его ещё нет.

- [ ] **Step 4: Прогнать тест**

Run: `cd push && node --test test/`
Expected: PASS.

- [ ] **Step 5: Подключить маршрут**

В роутере, сразу после блока `POST /register`:

```js
  if (request.method === 'POST' && request.url === '/turn') {
    const event = await readJson(request);
    // The same signature that proves a phone may register its push token
    // proves it may ask for a way to carry a call. One scheme, not two.
    if (!event || !verifyEvent(event) || event.kind !== REGISTER_KIND) {
      response.writeHead(401, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ ok: false, reason: 'signature' }));
      return;
    }
    const age = Math.abs(Math.floor(Date.now() / 1000) - event.created_at);
    if (age > REGISTER_MAX_AGE_SECONDS) {
      response.writeHead(401, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ ok: false, reason: 'stale' }));
      return;
    }
    try {
      const c = turnCredentials({
        secret: process.env.TURN_SECRET,
        ttlSeconds: TURN_TTL_SECONDS,
        nowSeconds: Math.floor(Date.now() / 1000),
      });
      log('turn', `${short(event.pubkey)} took a credential`);
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ ok: true, ...c, urls: TURN_URLS }));
    } catch (e) {
      log('turn', `refused: ${e.message}`);
      response.writeHead(503, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ ok: false, reason: 'unconfigured' }));
    }
    return;
  }
```

И константы рядом с прочими вверху файла:

```js
const TURN_TTL_SECONDS = 600;
const TURN_REALM = process.env.TURN_REALM || 'cubechat.tech';
const TURN_URLS = [
  `turn:turn.${TURN_REALM}:3478?transport=udp`,
  `turn:turn.${TURN_REALM}:3478?transport=tcp`,
  `turns:turn.${TURN_REALM}:5349?transport=tcp`,
];
```

`readJson` — то, чем уже читается тело в `/register`; если там это сделано
инлайном, повторить тот же способ, не вводя нового.

- [ ] **Step 6: Выкатить и проверить живьём**

Положить `TURN_SECRET` в `/etc/cubechat-push.env` (тот же, что в
`/etc/turnserver.conf`), выложить новый `index.js` и перезапустить службу.
Скопировать файл **с именем файла в назначении**, а не в каталог:

```bash
scp push/src/index.js root@209.38.225.225:/opt/cubechat-push/src/index.js
ssh root@209.38.225.225 "grep -q TURN_SECRET /etc/cubechat-push.env || (echo TURN_SECRET=\$(cat /etc/turnserver.secret) >> /etc/cubechat-push.env); systemctl restart cubechat-push && sleep 2 && systemctl is-active cubechat-push && curl -s -m 6 https://push.cubechat.tech/health"
```

Expected: `active` и прежний JSON здоровья.

- [ ] **Step 7: Доказать, что эндпоинт отказывает без подписи**

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'content-type: application/json' -d '{"kind":24242}' https://push.cubechat.tech/turn
```

Expected: `401`. Открытый эндпоинт выдачи доступа к ретранслятору — это
открытый ретранслятор.

- [ ] **Step 8: Коммит**

```bash
git add push/src/index.js push/test/ push/package.json
git commit -m "Hand out short-lived TURN access to whoever can already register a push token"
```

---

## Фаза Б — приложение

### Task 3: зависимость WebRTC и разрешения платформ

**Files:**
- Modify: `pubspec.yaml`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `ios/Runner/Info.plist`
- Test: `test/call_permissions_test.dart`

**Interfaces:**
- Produces: `flutter_webrtc` в зависимостях; `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS`,
  `BLUETOOTH_CONNECT` в манифесте Android; `NSMicrophoneUsageDescription` в
  `Info.plist`, если его там ещё нет.

- [ ] **Step 1: Добавить зависимость**

В `pubspec.yaml`, рядом с `record`/`audioplayers`, с комментарием, почему
именно она и почему не пишем своё:

```yaml
  # Voice calls. The media path only; the signalling is ours and rides the
  # same envelope text does (lib/core/transport/call_signal.dart).
  #
  # Not hand-rolled over the existing transport, though that was considered:
  # a jitter buffer, packet loss concealment, echo cancellation and bitrate
  # adaptation are most of what WebRTC is, and writing them is writing a
  # media stack rather than a messenger. See the design spec.
  flutter_webrtc: ^0.12.0
```

Резолюция проверена заранее: тянет только `webrtc_interface`, конфликтов с
текущим набором нет.

- [ ] **Step 2: Разрешения Android**

В `android/app/src/main/AndroidManifest.xml` добавить недостающие из:

```xml
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
```

`RECORD_AUDIO` уже есть ради голосовых сообщений — не дублировать, проверить
перед добавлением.

- [ ] **Step 3: Разрешение iOS**

В `ios/Runner/Info.plist` — `NSMicrophoneUsageDescription`, если отсутствует.
Текст по-английски, как остальные строки этого файла.

- [ ] **Step 4: Тест, который поймает пропажу разрешения**

Создать `test/call_permissions_test.dart`: прочитать манифест и plist как
файлы и проверить наличие строк. Тест на текстовый файл — не самая красивая
вещь на свете, но разрешение, исчезнувшее при слиянии, проявляется только на
устройстве и только в момент звонка.

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the android manifest asks for what a call needs', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    for (final permission in [
      'android.permission.RECORD_AUDIO',
      'android.permission.MODIFY_AUDIO_SETTINGS',
    ]) {
      expect(manifest, contains(permission), reason: '$permission is missing');
    }
  });

  test('ios explains why it wants the microphone', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, contains('NSMicrophoneUsageDescription'));
  });
}
```

- [ ] **Step 5: Прогнать и собрать**

Run: `flutter test --no-pub test/call_permissions_test.dart` — PASS.

Затем **собрать APK целиком**: добавление нативной зависимости — единственный
класс изменений, который зелёные тесты не ловят вообще, и в этом репозитории
уже был случай, когда добавленный плагин вытеснил другой и убил камеру на
всех телефонах (сборка 1012).

```bash
powershell -ExecutionPolicy Bypass -File tool/build_apk.ps1
```

Expected: `BUILD OK`, и размер APK записать в отчёт — прирост от WebRTC
ожидается заметный.

- [ ] **Step 6: Коммит**

```bash
git add pubspec.yaml pubspec.lock android/app/src/main/AndroidManifest.xml ios/Runner/Info.plist test/call_permissions_test.dart
git commit -m "Bring in the media stack, and ask for the microphone on both platforms"
```

---

### Task 4: доступ к TURN на стороне приложения

**Files:**
- Create: `lib/features/call/data/turn_credentials_controller.dart`
- Test: `test/turn_credentials_test.dart`

**Interfaces:**
- Consumes: подписывающий Nostr-ключ — тем же способом, каким
  `lib/core/notifications/push_registration.dart` подписывает регистрацию
  (прочитать его и повторить, не изобретая).
- Produces:
  - `class TurnAccess { final List<String> urls; final String username; final String password; final DateTime expiresAt; bool get isFresh; }`
  - `class TurnCredentialsController extends AsyncNotifier<TurnAccess?>` с методом
    `Future<TurnAccess> obtain()`, который отдаёт кэш пока он свеж и ходит на
    сервер иначе, и бросает `TurnUnavailable` когда не смог.
  - `class TurnUnavailable implements Exception { final String reason; }`
  - `final turnCredentialsProvider = AsyncNotifierProvider<TurnCredentialsController, TurnAccess?>(...)`

- [ ] **Step 1: Написать падающий тест**

Создать `test/turn_credentials_test.dart`. Поднять локальный `HttpServer` на
случайном порту и подсунуть контроллеру его адрес — тот же приём, что
`test/websocket_relay_client_test.dart` использует для реле.

Тесты, которые обязаны быть:
- удачный ответ разбирается, `expiresAt` = now + ttl;
- второй вызов `obtain()` в пределах свежести не ходит на сервер (счётчик
  запросов на фейковом сервере остаётся равен единице);
- вызов после истечения ходит снова;
- ответ 401 даёт `TurnUnavailable`, а не пустой доступ;
- ответ 503 `unconfigured` даёт `TurnUnavailable` с этой причиной;
- недоступный сервер (порт закрыт) даёт `TurnUnavailable`, а не зависание —
  таймаут не длиннее шести секунд;
- **ответ без `urls` или с пустым списком даёт `TurnUnavailable`.** Пустой
  список выглядит как успех и превращается в звонок без единого кандидата,
  то есть в тишину без причины.

- [ ] **Step 2: Убедиться, что тест падает**

Run: `flutter test --no-pub test/turn_credentials_test.dart` — FAIL, файла нет.

- [ ] **Step 3: Реализовать контроллер**

Свежесть считать с запасом: доступ, которому осталось меньше минуты, считать
несвежим, иначе звонок начнётся с кредитом, который умрёт посреди набора.

- [ ] **Step 4: Прогнать тест** — PASS.

- [ ] **Step 5: Коммит**

```bash
git add lib/features/call/data/turn_credentials_controller.dart test/turn_credentials_test.dart
git commit -m "Ask the push server for a way to carry a call, and cache it until it dies"
```

---

### Task 5: тумблер прямого соединения

**Files:**
- Create: `lib/features/profile/data/call_routing_controller.dart`
- Modify: экран настроек, где живут прочие тумблеры приватности
  (найти по `audioFocusProvider` — он уже там, и новый встаёт рядом)
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_uk.arb`
- Test: `test/call_routing_test.dart`

**Interfaces:**
- Produces: `class CallRoutingController extends Notifier<bool>` с ключом
  `call.allow_direct`, по умолчанию `false`, и
  `final callAllowsDirectProvider = NotifierProvider<CallRoutingController, bool>(...)`.
  Скопировать форму с `lib/features/profile/data/audio_focus_controller.dart`.

Ключи l10n: `callDirectTitle`, `callDirectSubtitle`. Английский текст:
`"Connect calls directly"` и `"Faster, but the person you call learns your IP address. Off means calls go through our relay, which never hears them."` Украинский — тот же смысл, в стиле соседних строк файла.

- [ ] **Step 1: Тест** — значение по умолчанию ложно; записанное переживает
  пересоздание контейнера. Форму взять из существующего теста настроек.
- [ ] **Step 2: Убедиться, что падает.**
- [ ] **Step 3: Реализовать контроллер и строки, прогнать `flutter gen-l10n`.**
- [ ] **Step 4: Добавить тумблер на экран настроек.**
- [ ] **Step 5: Прогнать тесты** — PASS.
- [ ] **Step 6: Коммит**

```bash
git commit -m "Let a person choose to trade their IP address for a shorter path"
```

---

### Task 6: `CallController` — машина, соединение и провод вместе

**Files:**
- Create: `lib/features/call/data/call_controller.dart`
- Test: `test/call_controller_test.dart`

**Interfaces:**
- Consumes: `CallStateMachine`, `CallPhase`, `CallOutcome`, `CallEndCause`
  (`lib/features/call/domain/call_state_machine.dart`); `CallSignal`,
  `CallSignalKind` (`lib/core/transport/call_signal.dart`);
  `MessagingService.sendCallSignal` и `MessagingService.callSignals`;
  `turnCredentialsProvider`; `callAllowsDirectProvider`.
- Produces:
  - `class CallSession { final String peerId; final String peerName; final CallPhase phase; final bool micMuted; final bool speakerOn; final Duration elapsed; }`
  - `class CallController extends Notifier<CallSession?>` с
    `Future<void> dial({required String canonicalId, required Uint8List peerPub, required String name})`,
    `Future<void> answer()`, `void decline()`, `void hangUp()`,
    `void toggleMute()`, `void toggleSpeaker()`
  - `final callControllerProvider = NotifierProvider<CallController, CallSession?>(...)`

**Что здесь обязательно, помимо очевидного:**

- Подписка на `messagingService.callSignals` заводится в `build` и
  отменяется при уничтожении. Приглашение уходит в `handleInvite`, всё
  остальное — в `handleSignal`.
- `RTCConfiguration` строится из полученного доступа, и
  `iceTransportPolicy` равен `'relay'`, **пока тумблер прямого соединения
  выключен**. При включённом — `'all'`.
- Если `obtain()` бросил `TurnUnavailable`, звонок не начинается: состояние
  сразу конечное с внятной причиной, приглашение не отправляется, и никакого
  перехода на `'all'` не происходит.
- Разрешение на микрофон спрашивается до `obtain()` и до приглашения.
- `mediaConnected()` вызывается по переходу `RTCPeerConnectionState` в
  `connected`; `mediaFailed()` — по `failed` **и** по `disconnected`,
  провисевшему дольше десяти секунд.
- Аудиофокус берётся безусловно на всё время звонка и отдаётся в конце.
- По приходу `CallOutcome` пишется запись в переписку через
  `encodeCallRecord` и путь добавления сообщения, которым уже пользуется
  `MessagingService`.

- [ ] **Step 1: Написать падающие тесты**

Тестируется всё, кроме самого WebRTC: соединение прячется за узким
интерфейсом `CallMedia` с методами `Future<String> offer(RTCConfiguration)`,
`Future<String> answer(RTCConfiguration, String remoteSdp)`,
`Future<void> accept(String remoteSdp)`, `Future<void> close()`,
`Stream<bool> get connected`, `void setMuted(bool)`, `void setSpeaker(bool)`,
и подменяется фейком. Это же и есть причина заводить интерфейс: `flutter_webrtc`
на хосте не поднимется никогда.

Тесты:
- набор без разрешения на микрофон не отправляет приглашения;
- `TurnUnavailable` завершает звонок с причиной и не отправляет приглашения;
- при выключенном тумблере в конфигурацию уходит `relay`, при включённом `all`;
- удачный набор отправляет приглашение с тем SDP, который вернул `offer`;
- пришедшее принятие ведёт к `accept` на медиа и к фазе `connecting`;
- `connected` из медиа переводит в `talking`;
- отбой закрывает медиа и отдаёт аудиофокус;
- исход звонка порождает ровно одну запись в переписке;
- пришедшее приглашение при выключенном экране звонка поднимает сессию в
  фазе `incoming`.

- [ ] **Step 2: Убедиться, что падают.**
- [ ] **Step 3: Реализовать контроллер и `CallMedia` поверх `flutter_webrtc`.**
- [ ] **Step 4: Прогнать тесты** — PASS.
- [ ] **Step 5: Полный прогон и анализатор.**
- [ ] **Step 6: Коммит**

```bash
git commit -m "Wire the call machine to a real connection, and refuse to route around the relay"
```

---

### Task 7: экран звонка и кнопка в профиле контакта

**Files:**
- Create: `lib/features/call/presentation/call_screen.dart`
- Modify: `lib/features/peers/presentation/contact_profile_screen.dart`
  (ряд действий, около строк 420–470 — там уже стоят «псевдоним»,
  «автоудаление», «обои», «поделиться»)
- Modify: маршрутизация (`lib/core/routing/`), чтобы экран звонка
  поднимался поверх всего
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_uk.arb`
- Test: `test/call_screen_test.dart`

**Перед написанием экрана загрузить навык `glass-ui`.**

Ключи l10n: `callAction` (`"Call"`), `callConnecting` (`"Connecting"`),
`callRinging` (`"Ringing"`), `callUnavailable` (`"Unavailable"`),
`callBusy` (`"Busy"`), `callDeclined` (`"Declined"`),
`callNoTurn` (`"Calls need our relay, and it cannot be reached right now."`),
`callMicDenied` (`"Calls need the microphone."`), `callHangUp` (`"End"`),
`callAnswer` (`"Answer"`), `callMute` (`"Mute"`), `callSpeaker` (`"Speaker"`).

Кнопка встаёт первой в ряду действий профиля, с `Icons.call_rounded` и
подписью `t.callAction`. Нажатие зовёт `dial` и открывает экран.

- [ ] **Step 1: Тесты экрана** — фаза отображается словами, а не кодом;
  кнопки отбоя, ответа, немого режима и динамика нажимаются и зовут
  контроллер; экран не ломается на узком телефоне; входящий звонок
  показывает имя звонящего.
- [ ] **Step 2: Тест кнопки в профиле** — кнопка присутствует и зовёт `dial`
  с идентификатором этого контакта.
- [ ] **Step 3: Убедиться, что падают.**
- [ ] **Step 4: Реализовать экран, кнопку, маршрут и строки.**
- [ ] **Step 5: Прогнать тесты** — PASS.
- [ ] **Step 6: Коммит**

```bash
git commit -m "Put a call behind a button in the contact profile, and give it a screen"
```

---

### Task 8: пять находок, оставленных первой частью

**Files:**
- Modify: `lib/features/call/domain/call_state_machine.dart`
- Modify: `lib/core/transport/messaging_service.dart`
- Modify: `lib/features/chat/domain/message_preview.dart`
- Test: `test/call_state_machine_outgoing_test.dart`,
  `test/call_state_machine_incoming_test.dart`, `test/message_preview_test.dart`

Раздел «Что этот план оставил следующим» в
`docs/superpowers/plans/2026-09-10-calls-wire-and-state-machine.md` перечисляет
их полностью; здесь короткий список с тем, что делать.

- [ ] **Step 1: Принятие, пришедшее раньше подтверждения.** Ветка `accept`
  в `handleSignal` срабатывает только из `ringing`. Разрешить её и из
  `dialing`: подтверждение могло потеряться, а принятие дойти. Тест: из
  `dialing`, без единого `ringing`, принятие переводит в `connecting`.
- [ ] **Step 2: Дедлайн у фазы `connecting`.** Вооружить таймером —
  тридцать секунд, после чего `mediaFailed`-подобное завершение с причиной
  `failed` и отбоем. Тест на срабатывание и на то, что `mediaConnected`
  его снимает.
- [ ] **Step 3: `sendCallSignal` возвращает число звеньев,** а не `void`, и
  `CallController` считает нулевой результат поводом завершить звонок с
  внятной причиной, а не ждать восемь секунд под чужим ярлыком.
- [ ] **Step 4: Двойной `notifyListeners` на проигранном встречном вызове.**
  Собрать переход в один: не звать `_move(ended)` внутри `_end`, когда сразу
  следом ставится `incoming`. Тест: слушатель за один вызов `handleInvite`
  получает ровно одно уведомление.
- [ ] **Step 5: `storedTextPreview` показывает запись о звонке как base64.**
  Научить его тому же, чему в части 1 научили `_textPreview`. Тест на обе
  функции.
- [ ] **Step 6: Полный прогон, анализатор, коммит**

```bash
git commit -m "Close what the wire plan wrote down and left"
```

---

## Чего этот план не делает

- Не поднимает CallKit, PushKit, службу переднего плана и полноэкранное
  намерение. Входящий звонок виден только при открытом приложении.
- Не учит пуш-сервер читать флаг `c`: читать его имеет смысл только когда
  есть кому доложить о звонке.
- Не делает видео, групп и звонков по мешу.
- Не подаёт экспортное согласование, без которого App Store закрыт.
