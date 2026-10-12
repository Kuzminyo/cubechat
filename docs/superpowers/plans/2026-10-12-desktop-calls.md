# Звонки на ПК и «один звонок на аккаунт» — план

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** звонки работают на Windows, и у аккаунта никогда не идёт больше одного звонка одновременно.

**Architecture:** новый вид `device` (0x07) в существующем `callSignal` летит только на собственный ключ через реле; `CallController` по нему глушит звонок, отказывает в наборе и молчит на приглашения, пока другое устройство в звонке. На Windows — возвращённая из pub-кэша Windows-часть `flutter_webrtc` и своя поверхность входящего (уведомление + рингтон).

**Tech Stack:** Flutter/Riverpod, flutter_webrtc 0.12.12+hotfix.1 (вендорная копия), local_notifier, audioplayers, fake_async.

**Spec:** `docs/superpowers/specs/2026-10-12-desktop-calls-design.md`

## Global Constraints

- Kind `device` = `0x07`; state `free 0x00`, `busy 0x01`, `declined 0x02`.
- Только на собственный ключ, `relayOnly`, без `w`/`c` (ни `callWakesPeer`, ни `callIsVoipWake`).
- Принимается только от собственного ключа.
- `ownDeviceHeartbeat` = 20 с, `ownDeviceSilence` = 60 с, в `call_rules.dart`.
- `PlatformCapabilities.calls`: Android, iOS, Windows — да; macOS, Linux, web — нет.
- Строки через `AppLocalizations`, en+uk, `flutter gen-l10n`.
- Не трогать существующие тайминги звонков.

## Review Focus

1. Самоадресованный кадр отброшен фильтром незнакомцев / `allowed` → тест в Task 2 и Task 4 (`device` от себя проходит, `allowed` для себя не спрашивается).
2. `device` от чужого ключа → отброшен (Task 4).
3. Устройство упало без `free` → через 60 с снова можно звонить (Task 4).
4. Ответили на другом устройстве — здесь не пишется вторая запись в историю и не уходит `decline`/`hangup` звонящему (Task 3, Task 4).
5. Добавление kind ломает исчерпывающие `switch` — все места решены явно, без `default` (Task 1).

---

### Task 1: Кодек `device`

**Files:** `lib/core/transport/call_signal.dart`, `lib/features/call/domain/call_rules.dart`, места исчерпывающих switch в `call_controller.dart` / `call_state_machine.dart`; тесты `test/call_signal_test.dart`, `test/call_rules_test.dart`.

**Produces:** `CallSignalKind.device`, `enum CallDeviceState { free(0x00), busy(0x01), declined(0x02) }` с `fromByte` (бросает `FormatException` на чужой байт), `CallSignal.device({required Uint8List callId, required CallDeviceState state})`, поле `CallSignal.deviceState`.

- [ ] Тест: round-trip для трёх состояний; тело пустое → `FormatException`; state `0x09` → `FormatException`; kind `0x08` по-прежнему `FormatException`; `callWakesPeer(device)` и `callIsVoipWake(device)` — false.
- [ ] Запустить `flutter test --no-pub test/call_signal_test.dart test/call_rules_test.dart` — падает (нет `device`).
- [ ] Реализовать; в `_undeliverableEndsCall` → `false`, в `CallStateMachine.handleSignal` → `return`, в `_settleStale` → `return`.
- [ ] Тесты зелёные, `flutter analyze` без ошибок по затронутым файлам. Коммит.

### Task 2: Отправка на свои устройства и приём от себя

**Files:** `lib/core/transport/messaging_service.dart` (рядом с `sendCallSignal`), тест рядом с существующими тестами транспорта звонков (`test/call_transport_tags_test.dart` — образец).

**Produces:** `Future<ControlDelivery> sendCallSignalToOwnDevices(CallSignal signal)` — `peerPub` = собственный X25519 ключ, `canonicalId` = его hex, `relayOnly: true`, `wakesPeer/wakesCall: false`. Входящий `callSignal` от собственного ключа доходит до `callSignals` с `chatId` = собственный hex.

- [ ] Найти, отбрасывает ли путь входящих кадров отправителя «не из контактов» до `case InnerPayloadType.callSignal` (настройка «незнакомцы»); если да — пропустить собственный ключ.
- [ ] Тест (по образцу `call_transport_tags_test.dart`): кадр уходит только на реле, без тегов `w`/`c`; если путь входящих тестируем — кадр от себя доходит до потока.
- [ ] Реализовать, тесты зелёные. Коммит.

### Task 3: Машина состояний — тихий конец

**Files:** `lib/features/call/domain/call_state_machine.dart`, `lib/features/call/domain/call_record.dart`; тест `test/call_state_machine_incoming_test.dart`, `test/call_record_test.dart`.

**Produces:** `CallEndCause.elsewhere`; `void endElsewhere()` — только из `incoming`, ничего не отправляет, `_end(elsewhere, CallEndSource.remote)`; `void yieldToOwnDevice()` — из `dialing`/`ringing`: `hangup(hungUp)` собеседнику и `_end(glareLost, remote)`. `encodeCallRecord` для `elsewhere` возвращает `''` (контроллер тогда ничего не пишет).

- [ ] Тесты: `endElsewhere` в `incoming` → `ended`, `send` не вызван, outcome `elsewhere`; в `talking` — ничего; `yieldToOwnDevice` шлёт hangup и даёт `glareLost`; запись для `elsewhere` пустая.
- [ ] Красные → реализовать → зелёные. Коммит.

### Task 4: Контроллер — один звонок на аккаунт

**Files:** `lib/features/call/data/call_controller.dart`, `lib/features/call/domain/call_rules.dart`; тест `test/call_controller_test.dart` (новая группа, под `fakeAsync`, контроллер строится внутри `fakeAsync`).

**Consumes:** Task 1–3. **Produces:** параметры конструктора `String Function()? ownId` (по умолчанию `''` — «себя нет») и `Future<ControlDelivery> Function(CallSignal)? notifyOwnDevices` (по умолчанию no-op); `CallTimings.ownDeviceHeartbeat`, `CallTimings.ownDeviceSilence`; ошибка `'elsewhere'`.

Поведение (из спеки):
- `device` принимается до проверки `allowed`, и только если `chatId == ownId()` и `ownId()` не пуст; иначе лог и отброс. Любой другой kind от себя — отброс.
- busy(X): звоню по X или по другому входящему → `endElsewhere()`; я `dialing/ringing` → если мой `callId` больше X (`winsGlare(mine: X, theirs: mine)` уже есть) → `yieldToOwnDevice()`; иначе игнор; в любом случае запомнить `(X, now + silence)`.
- declined(X): звоню по X → `endElsewhere()`.
- free(X): забыть, если это X.
- invite при живом чужом звонке → лог, не звонить, не отвечать.
- `dial` при живом чужом звонке → `error = 'elsewhere'`, ничего не отправлять.
- Свои уведомления: busy — при `startOutgoing` и при `accept`; повтор каждые 20 с пока `isLive` и звонок «мой»; free — в `_outcome`, если звонок был «моим» (набирал или ответил); declined — в `decline()`.
- Провайдер: `ownId` из `identityProvider` (hex X25519, тот же формат, что `chatId`), `notifyOwnDevices` → `messaging.sendCallSignalToOwnDevices`.

- [ ] Тесты: (a) ответили на другом → фаза ended, звонящему ничего, outcome `elsewhere`; (b) отклонили на другом → так же; (c) набор при чужом busy → `error == 'elsewhere'`, `sent` пуст; (d) приглашение при чужом busy → не звонит, ничего не отправлено; (e) через 61 с без повтора набор проходит; (f) повтор busy каждые 20 с, free в конце; (g) одновременный набор: мой `callId` больше → hangup собеседнику; (h) `device` от `'peer'` → игнор; (i) declined уходит при `decline()`.
- [ ] Красные → реализовать → зелёные; весь `call_controller_test.dart` зелёный. Коммит.

### Task 5: Windows — возможности, микрофон, поверхность, тексты

**Files:** `lib/core/util/platform_capabilities.dart`, `lib/features/call/data/call_controller.dart` (провайдер), `lib/features/call/data/incoming_call_surface.dart`, `lib/l10n/app_*.arb`, место, где экран звонка переводит `error` в текст (`call_screen.dart`); тесты `test/platform_capabilities_test.dart`, новый `test/windows_call_surface_test.dart`.

**Produces:** `calls: true` только для `TargetPlatform.windows` среди десктопов; `WindowsIncomingCallSurface({required IncomingCallLabels Function() labels, CallTones? tones, DesktopCallToast? toast})` с `ringsInForeground = true`; `platformCallSurface` возвращает её на Windows; ключи `callErrorElsewhere`, `callErrorMicrophoneWindows`.

- [ ] Тест возможностей (Windows да, macOS/Linux нет) и поверхности с фейковым toast/tones: `show` → тон incoming + уведомление; `answered`/`dismiss` → стоп + закрыть; нажатие «Відповісти» в уведомлении → `actions` выдаёт `answer`.
- [ ] Микрофон на десктопе: `true` (запрет ловится как ошибка media → на Windows текст про настройки).
- [ ] Красные → реализовать → зелёные. Коммит.

### Task 6: WebRTC под Windows

**Files:** `third_party/flutter_webrtc/windows/**`, `third_party/flutter_webrtc/third_party/{uuidxx,svpng,libwebrtc/include,libwebrtc/lib/win64}`, `third_party/flutter_webrtc/pubspec.yaml`, `third_party/flutter_webrtc/CUBECHAT_PATCH.md`.

- [ ] Скопировать из `%LOCALAPPDATA%/Pub/Cache/hosted/pub.dev/flutter_webrtc-0.12.12+hotfix.1/` перечисленное (без linux/elinux).
- [ ] `pubspec.yaml` плагина: `windows: pluginClass: FlutterWebRTCPlugin`; поправить комментарий про удалённые платформы.
- [ ] `CUBECHAT_PATCH.md`: раздел «Windows вернули (2026-10-12)» — что и откуда, проверка при обновлении.
- [ ] `powershell -ExecutionPolicy Bypass -File tool/build_windows.ps1` — сборка проходит, `build/windows/x64/runner/Release/libwebrtc.dll` есть. Коммит.

### Task 7: Документы, версия, сборки

**Files:** `docs/legal/privacy-policy.{en,uk}.md` (звонки), `.claude/skills/calls/SKILL.md` (таблица kinds + раздел про свои устройства и Windows), `.claude/skills/wire-protocol/SKILL.md` при необходимости, `pubspec.yaml`, `lib/core/util/app_build.dart`.

- [ ] Политика: звонки и с компьютера; устройства одного аккаунта сообщают друг другу о звонке через реле, зашифровано на собственный ключ.
- [ ] Скиллы: строка `0x07 device [state:1]`, правило «только себе/только от себя», 20/60 с, Windows-поверхность.
- [ ] Весь набор `flutter test --no-pub --exclude-tags golden` зелёный, `flutter analyze` без error/warning.
- [ ] Версия 1146 + штамп, сборка Windows ZIP и APK (`tool/build_apk.ps1`). Коммит.
