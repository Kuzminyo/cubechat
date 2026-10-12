# Устройства аккаунта — план

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** список устройств аккаунта и выход на любом другом.

**Architecture:** `InnerPayloadType.ownDevice` (0xEB) с кодеком `OwnDeviceNotice`, отправка себе через реле (общий путь со звонками), `OwnDevicesController` держит список и номер, выход = очистка без освобождения @ника.

**Tech Stack:** Flutter/Riverpod, Hive (зашифрованный), flutter_secure_storage, go_router.

**Spec:** `docs/superpowers/specs/2026-10-12-own-devices-design.md`

## Global Constraints

- Тип 0xEB; формат `[0x01][kind][sentAtMs:8][deviceId:16][тело]`; hello 0x01, signOut 0x02, goodbye 0x03; имя ≤ 64 байт.
- Только себе / только от себя; переживает окно повторов.
- Номер и имя — в secure storage, не в Hive.
- hello каждые 6 ч; забывать молчащих 60 дней.
- Строки en+uk, `flutter gen-l10n`.

## Review Focus

1. `signOut` с чужим номером не стирает это устройство (Task 3).
2. Выход не освобождает @ник (Task 4).
3. Устройство из резервной копии не наследует номер (Task 3: номер не в Hive).
4. Повтор старого `hello` не откатывает «был в сети» назад (Task 3).
5. `hello` с флагом не вызывает бесконечный обмен (Task 3).

---

### Task 1: Кодек `OwnDeviceNotice` и тип 0xEB
**Files:** create `lib/core/transport/own_device_notice.dart`; modify `lib/core/transport/inner_payload.dart`, исчерпывающие switch (`opensRequest` → false, `survivesReplayWindow` → true); test `test/own_device_notice_test.dart`.
**Produces:** `enum OwnDeviceKind { hello(0x01), signOut(0x02), goodbye(0x03) }`, `enum DevicePlatform { unknown(0), android(1), ios(2), windows(3), macos(4), linux(5) }` с `fromByte` (неизвестное → unknown), `class OwnDeviceNotice { kind, sentAtMs, deviceId (Uint8List 16), answerRequested, platform, name, targetId; factories hello/signOut/goodbye; encode(); static decode() }`.
- [ ] Тесты: round-trip трёх видов; версия 2 / обрезка / имя > 64 / nameLen за пределами → `FormatException`; 0xEB свободен до этого (тип = 0xEB).
- [ ] Красные → реализация → зелёные. Коммит.

### Task 2: Отправка себе любого типа и приём `ownDevice`
**Files:** `lib/core/transport/messaging_service.dart`.
**Produces:** `Future<ControlDelivery> sendOwnDeviceNotice(OwnDeviceNotice n)`; общий `_sendToOwnDevices(type, body)` (звонки идут через него же); поток `Stream<OwnDeviceNotice> get ownDeviceNotices`; во входящих `case InnerPayloadType.ownDevice` — только от собственного ключа, иначе лог и отброс; `FormatException` — лог.
- [ ] Тесты звонков и транспорта остаются зелёными; analyze чистый. Коммит.

### Task 3: `OwnDevicesController`
**Files:** create `lib/features/devices/data/own_devices_controller.dart`, `lib/features/devices/data/device_identity.dart`; test `test/own_devices_controller_test.dart`.
**Produces:** `DeviceIdentityStore` (интерфейс: `Future<Uint8List> id()`, `Future<String?> name()`, `setName`, `wipe`) + реализация на secure storage; `OwnDevice { idHex, name, platform, lastSeen, leaving }`; `OwnDevicesController extends Notifier<List<OwnDevice>>` с `start()` (hello с флагом, таймер 6 ч), `rename(String)`, `signOut(String idHex)`, `signOutOthers()`, `Stream<void> get signedOutHere`; зависимости — провайдеры для отправителя, потока входящих и хранилища (подменяются в тестах).
- [ ] Тесты из спеки (hello с флагом при старте; ответ без флага; max времени; signOut чужой — игнор; свой — событие `signedOutHere` и `goodbye` отправлен; goodbye убирает; 60 дней — убирает; rename шлёт hello).
- [ ] Красные → реализация → зелёные. Коммит.

### Task 4: Выход этого устройства
**Files:** `lib/core/identity/wipe_service.dart` (`emergencyWipe(ref, {bool releaseName = true})`, стирает и `DeviceIdentityStore`); `lib/app.dart` (слушает `signedOutHere` → `emergencyWipe(ref, releaseName: false)`; запускает `start()` контроллера); test — выбор: юнит-тест на флаг `releaseName` через фейковый cubeId-контроллер, если собирается без всего приложения; иначе тест контроллера, что событие выхода выдаётся.
- [ ] Коммит.

### Task 5: Экран «Пристрої»
**Files:** create `lib/features/devices/presentation/devices_screen.dart`; route `/devices` в `app_router.dart`; строка в `data_section.dart`; строки arb; test `test/devices_screen_test.dart` (список, переименование, подтверждение выхода и «вийти на всіх»).
- [ ] Коммит.

### Task 6: Документы, версия, сборки
- [ ] Политика (en/uk), скилл wire-protocol (0xEB в таблице), версия 1147 + штамп; весь набор зелёный; сборки Windows ZIP и APK. Коммит.
