# CubeChat для Windows — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `CubeChat.exe` для Windows: свой аккаунт или копия аккаунта телефона, связь через интернет-реле.

**Architecture:** Та же кодовая база Flutter, цель `windows`. Одна точка правды о том, что умеет платформа (`PlatformCapabilities`), прячет мобильные функции. Привязка к телефону — обратный перенос: ПК поднимает одноразовый TCP-сервер и показывает QR `cubechat:l1:`, телефон шлёт туда зашифрованную резервную копию тем же `BackupService`, что у переноса между телефонами.

**Tech Stack:** Flutter 3.41 (Windows desktop), Riverpod, Hive, `dart:io` сокеты, Inno Setup, GitHub Actions `windows-latest`.

**Spec:** `docs/superpowers/specs/2026-10-10-windows-desktop-design.md`

## Global Constraints

- Только интернет-реле на Windows: mesh, BLE, AirDrop не запускаются (уже: `_startDiscovery` проверяет `PlatformInfo.isMobile`).
- Телефон после отправки аккаунта на ПК ничего у себя не стирает.
- ПК с аккаунтом телефона никогда не ротирует предключи и ключ личности.
- Новый вид QR — `cubechat:l1:`, в https-обёртке `https://cubechat.app/l1#`, токен и пароль во фрагменте.
- Проверка «что умеет платформа» — только через `PlatformCapabilities`, без россыпи `Platform.isWindows` по экранам.
- Все строки интерфейса — через `AppLocalizations`, ключи в `app_en.arb` и `app_uk.arb` одновременно, затем `flutter gen-l10n`.
- Не-ASCII в файлах писать только через Write/Edit (Bash и PowerShell портят кириллицу).

## Review Focus

1. ПК и телефон в разных сетях (или Wi-Fi с изоляцией клиентов): телефон не может подключиться — должна быть понятная ошибка за ~12 с, а не вечный спиннер.
2. QR привязки отсканирован дважды или вторым телефоном: сервер одноразовый, второй получает отказ, данные ПК не перезаписываются.
3. Резервная копия больше `maxTransferBytes` (128 МБ, медиа): телефон говорит об этом до подключения.
4. Ширина окна меняется на лету через 900 px с открытым чатом: открытый чат не теряется.
5. Старое сохранённое расположение вкладок с «Поблизу» и «Мапой»: на ПК они отфильтровываются, панель не пустеет.

---

### Task 1: Windows-сборка собирается, скрипт выдачи

**Files:**
- Modify: `windows/CMakeLists.txt` (определение для всех целей)
- Create: `tool/build_windows.ps1`
- Modify: `windows/installer/cubechat.iss` (версия из параметра)

**Interfaces:** Produces: `build\windows\x64\runner\Release\cubechat.exe`, `build\CubeChat-<ver>-windows.zip`, при наличии Inno Setup `build\CubeChat-<ver>-setup.exe`.

- [ ] **Step 1:** В `windows/CMakeLists.txt` после `add_definitions(-DUNICODE -D_UNICODE)` добавить:

```cmake
# Visual Studio 18 refuses <experimental/coroutine> outright (STL1011), and
# audioplayers_windows and permission_handler_windows still build with /await.
# Silenced for every target until those plugins move to C++20 coroutines.
add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)
```

- [ ] **Step 2:** `flutter build windows --release` из bash. Expected: `Built build\windows\x64\runner\Release\cubechat.exe`. Если падает ещё что-то — чинить по одному и записать ruling.
- [ ] **Step 3:** `tool/build_windows.ps1`: сверить `version:` pubspec с `appVersion` и штампом (как `build_apk.ps1`), запустить `flutter build windows --release` через `bash -lc` (flutter есть только в PATH bash), найти штамп в `build\windows\x64\runner\Release\data\app.so`, собрать ZIP, вызвать `ISCC.exe /DAppVersion=<ver>` если найден.
- [ ] **Step 4:** В `cubechat.iss` заменить `#define AppVersion "0.1.0"` на `#ifndef AppVersion` / `#define AppVersion "dev"` / `#endif`, имя `CubeChat`.
- [ ] **Step 5:** Запустить скрипт, проверить что exe стартует (процесс жив через 10 с). Commit.

### Task 2: `PlatformCapabilities` и вкладки

**Files:**
- Create: `lib/core/util/platform_capabilities.dart`
- Modify: `lib/features/profile/data/nav_bar_controller.dart` (`_sanitise`, `NavBarLayout.initial`)
- Test: `test/platform_capabilities_test.dart`

**Interfaces:** Produces:
```dart
class PlatformCapabilities {
  const PlatformCapabilities({required this.bluetooth, required this.maps,
    required this.camera, required this.calls, required this.translation,
    required this.gallery});
  final bool bluetooth, maps, camera, calls, translation, gallery;
  static PlatformCapabilities forPlatform(TargetPlatform p, {bool web = false});
  static PlatformCapabilities get current; // forPlatform(defaultTargetPlatform, web: kIsWeb)
}
```
Android и iOS — всё `true`. Windows/macOS/Linux/web — всё `false`.

- [ ] **Step 1:** Тест: `forPlatform(TargetPlatform.windows)` — все false; android — все true; `NavBarLayout` на Windows из сохранённого `[chats, peers, map, profile]` даёт `[chats, profile]` и не короче двух.
- [ ] **Step 2:** Запустить — FAIL (нет класса).
- [ ] **Step 3:** Реализовать; в `_sanitise` выкинуть `peers` без `bluetooth` и `map` без `maps`; `initial` на ПК — без них же. Если после фильтра меньше `minimumTabs` — `[chats, contacts, profile]`.
- [ ] **Step 4:** PASS, commit.

### Task 3: Спрятать мобильные функции

**Files (найдены grep):** звонки — `contacts_screen.dart`, `recent_calls_view.dart`, `contact_profile_screen.dart`, кнопка в шапке чата `chat_screen.dart`; камера — `attach_island.dart`, `media_picker_sheet.dart`, `chat_screen.dart`, `profile_screen.dart`, `channel_info_screen.dart`; перевод — меню сообщения в `chat_screen.dart`; галерея — `media_picker_sheet.dart` (на ПК — сразу выбор файла через `file_picker`); AirDrop/«Поблизу» — `app.dart` (`ShareInbox` уже только мобильный), ссылки в `message_bubble.dart`.

- [ ] **Step 1:** Виджет-тест с `debugDefaultTargetPlatformOverride = TargetPlatform.windows`: в шапке чата нет кнопки звонка; в меню вложений нет «Камера», «Галерея» ведёт к выбору файла.
- [ ] **Step 2:** FAIL.
- [ ] **Step 3:** Каждое место обернуть в `if (PlatformCapabilities.current.<x>)`. Входящий `callSignal` на ПК: ответить `busy` — тогда звонящий услышит «занято», а не вечный гудок.
- [ ] **Step 4:** PASS, полный набор тестов, commit.

### Task 4: Две колонки от 900 px

**Files:**
- Create: `lib/features/desktop/desktop_split_view.dart`
- Modify: `lib/core/routing/app_router.dart` (shell builder: при ширине ≥ 900 — `DesktopSplitView`)
- Test: `test/desktop_split_view_test.dart`

**Interfaces:** `DesktopSplitView({required Widget list, required Widget? detail})`; выбор чата на широком окне открывает его справа (`desktopSelectedChatProvider: StateProvider<String?>`), на узком — обычный `push`.

- [ ] **Step 1:** Тест: ширина 1200 — тап по чату показывает список и чат одновременно; ширина 600 — только чат. Смена ширины 1200→600 с открытым чатом оставляет чат открытым.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** PASS, commit.

### Task 5: Протокол привязки `cubechat:l1:`

**Files:**
- Create: `lib/features/backup/data/desktop_link_service.dart`
- Test: `test/desktop_link_test.dart`

**Interfaces:** Produces:
```dart
class DesktopLinkPayload { // как PhoneTransferPayload, prefix 'cubechat:l1:', linkPrefix 'https://cubechat.app/l1#'
  String encode(); static DesktopLinkPayload? tryDecode(String raw);
}
class DesktopLinkService {
  Future<DesktopLinkSession> startReceiving(); // ПК: сервер + payload, одноразовый
  Future<void> sendTo(DesktopLinkPayload p);   // телефон: token, затем backup(password)
}
class DesktopLinkSession { String get qr; Future<void> get done; Future<void> cancel(); }
```
Протокол: клиент шлёт `token` (ASCII), затем 8 байт длины big-endian, затем зашифрованную копию; сервер сверяет токен, длину ≤ `PhoneTransferService.maxTransferBytes`, читает ровно столько, вызывает `BackupService.restore(bytes, password: payload.password)`, отвечает байтом `0x01` при успехе.

- [ ] **Step 1:** Тесты: кодек туда-обратно; `tryDecode` отвергает `cubechat:t1:`, мусор, токен/пароль короче 20; loopback сервер↔клиент с подменённым `BackupService` (create → фиксированные байты, restore — записывает полученное): байты доехали, второй клиент отвергнут, неверный токен — соединение закрыто без restore.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** PASS, commit.

### Task 6: Экраны привязки

**Files:**
- Modify: онбординг (`lib/features/onboarding/...`) — вторая кнопка «Увійти акаунтом телефона» только при `!PlatformCapabilities.current.bluetooth`.
- Create: `lib/features/backup/presentation/desktop_link_screen.dart` — QR, адрес, ожидание, ошибки, текст ограничений v1.
- Modify: `lib/features/profile/presentation/settings/data_section.dart` — «Підключити комп'ютер» (только на телефоне) → сканер.
- Modify: `lib/features/qr/presentation/qr_scanner_screen.dart` — распознать `cubechat:l1:` → подтверждение → `sendTo`.
- Modify: `lib/l10n/app_en.arb`, `app_uk.arb`.

- [ ] **Step 1:** Виджет-тест: сканер, получив строку `l1`, показывает подтверждение «Надіслати копію акаунта на комп'ютер?», а не экран переноса `t1`.
- [ ] **Step 2–4:** FAIL → реализовать → PASS, commit.

### Task 7: Уведомления и перетаскивание файлов

- [ ] Уведомления Windows: пакет `local_notifier` (только desktop, мобильные не трогает); `NotificationService.showMessage` на ПК — тост, клик открывает чат.
- [ ] Перетаскивание: пакет `desktop_drop`; `DropTarget` вокруг чата, отпущенные файлы идут тем же путём, что выбранные через `file_picker` (картинки — как фото).
- [ ] Тест: картинка, брошенная в чат, вызывает путь отправки фото (подменённый `messagingService`). Commit.

### Task 8: CI и комментарий о ключах

- [ ] `.github/workflows/windows.yml`: `windows-latest`, flutter 3.41.x, `flutter build windows --release`, ZIP как артефакт релиза `windows-latest` (не workflow-artifact — квота).
- [ ] Комментарий в `lib/core/crypto/prekey_service.dart` над ротацией: привязанный ПК держит те же ключи; ротация должна их учитывать.
- [ ] Полный прогон, `tool/build_windows.ps1`, ручная проверка: exe запускается, онбординг, сообщение через реле туда и обратно. Commit.
