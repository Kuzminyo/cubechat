# Право доступа Pro и экран покупки — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** довести покупку Pro до рабочего состояния на обоих сторах и завести
флаг `isPro`, который пока **никто не читает**, — чтобы биллинг был проверен на
живых сторах раньше, чем от него что-то начнёт зависеть.

**Architecture:** значение (`ProState`) отделено от источника
(`EntitlementSource`) и от потребителя (`ProController`). Источник на этом
этапе один — чек стора через `in_app_purchase`; второй, со слепо подписанными
токенами, встанет рядом на этапе 2 без переписывания. Всё, что решает логика,
вынесено в чистые функции, поэтому проверяется без плагина и без телефона.
Состояние кэшируется в Hive, чтобы интерфейс не мигал заблокированным на
холодном старте.

**Tech Stack:** Dart, Flutter >= 3.27, `flutter_riverpod` ^2.5.1, `hive` ^2.2.3,
`in_app_purchase` (добавляется в этом плане), `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-09-17-pro-subscription-design.md`

## Global Constraints

- Ничего из того, что сегодня работает бесплатно, этот план не блокирует. По
  завершении план не меняет поведение приложения ни для кого: флаг существует и
  не читается.
- Анализатор строгий: `strict-casts`, `strict-inference`, `strict-raw-types`,
  `prefer_final_locals`, `prefer_const_constructors`, `require_trailing_commas`,
  `avoid_print`.
- Проверка анализатора — с обоими разделителями, разделитель отличается на
  Windows и на CI:
  `flutter analyze 2>&1 | grep -E "^[[:space:]]*(error|warning)[[:space:]]*[-•]"`
- Локали две: `lib/l10n/app_en.arb` и `lib/l10n/app_uk.arb`. Новая строка
  добавляется в обе, затем `flutter gen-l10n`. Русской локали в проекте нет.
- Каталог фичи: `lib/features/pro/{data,models,presentation}` — как у остальных
  фич.
- Тесты лежат плоско в `test/`, без подкаталогов.
- Идентификаторы товаров: `pro.monthly`, `pro.yearly`, `pro.lifetime`.
- Версию и `appBuildStamp` этот план не трогает: сборка APK сюда не входит.

---

### Task 1: Значение — `ProState` и `ProProduct`

Чистый слой без ввода-вывода. Он первый, потому что на его имена опираются все
остальные задачи.

**Files:**
- Create: `lib/features/pro/models/pro_state.dart`
- Test: `test/pro_state_test.dart`

**Interfaces:**
- Consumes: ничего.
- Produces: `enum ProSource { none, subscription, lifetime }`;
  `enum ProProduct { monthly, yearly, lifetime }` с `String get storeId`;
  `ProProduct? proProductFromStoreId(String id)`;
  `class ProState` с полями `ProSource source`, `bool loaded`, геттером
  `bool get isActive`, константами `ProState.unknown` и `ProState.free`,
  методом `ProState copyWith({ProSource? source, bool? loaded})`,
  `operator ==` и `hashCode`.

- [ ] **Step 1: Write the failing test**

Создать `test/pro_state_test.dart`:

```dart
import 'package:cubechat/features/pro/models/pro_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProState', () {
    test('unknown is not active and not loaded', () {
      // The difference that matters on a cold start: we do not yet know, which
      // is not the same as "no". A screen that treats unknown as locked shows
      // a padlock for a moment to somebody who paid.
      expect(ProState.unknown.loaded, isFalse);
      expect(ProState.unknown.isActive, isFalse);
    });

    test('free is loaded and not active', () {
      expect(ProState.free.loaded, isTrue);
      expect(ProState.free.isActive, isFalse);
    });

    test('either paid source is active', () {
      const sub = ProState(source: ProSource.subscription, loaded: true);
      const life = ProState(source: ProSource.lifetime, loaded: true);
      expect(sub.isActive, isTrue);
      expect(life.isActive, isTrue);
    });

    test('compares by value, so an equal rebuild is a no-op', () {
      const a = ProState(source: ProSource.lifetime, loaded: true);
      const b = ProState(source: ProSource.lifetime, loaded: true);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(ProState.free)));
    });

    test('loaded is part of identity', () {
      // Otherwise "not known yet" and "known to be free" collide, and the
      // padlock flash comes back through the equality check.
      const notYet = ProState(source: ProSource.none, loaded: false);
      expect(notYet, isNot(equals(ProState.free)));
    });

    test('store ids round-trip', () {
      for (final p in ProProduct.values) {
        expect(proProductFromStoreId(p.storeId), equals(p));
      }
      expect(proProductFromStoreId('pro.nonsense'), isNull);
    });

    test('store ids are the ones registered in both stores', () {
      expect(ProProduct.monthly.storeId, 'pro.monthly');
      expect(ProProduct.yearly.storeId, 'pro.yearly');
      expect(ProProduct.lifetime.storeId, 'pro.lifetime');
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/pro_state_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:cubechat/features/pro/models/pro_state.dart'`.

- [ ] **Step 3: Write minimal implementation**

Создать `lib/features/pro/models/pro_state.dart`:

```dart
import 'package:flutter/foundation.dart';

/// Where the right to Pro came from.
enum ProSource { none, subscription, lifetime }

/// What can be bought. The ids are what both stores are configured with.
enum ProProduct {
  monthly('pro.monthly'),
  yearly('pro.yearly'),
  lifetime('pro.lifetime');

  const ProProduct(this.storeId);

  final String storeId;

  ProSource get source =>
      this == ProProduct.lifetime ? ProSource.lifetime : ProSource.subscription;
}

/// The store's id back to the product, or null for anything we do not sell.
ProProduct? proProductFromStoreId(String id) {
  for (final p in ProProduct.values) {
    if (p.storeId == id) return p;
  }
  return null;
}

/// Whether this device may use Pro.
///
/// **No expiry date, deliberately.** `in_app_purchase` reports the status of a
/// purchase, not the day it runs out; an honest end date needs the receipt
/// checked against Apple and Google, which is stage two and needs a server.
/// The store is the source of truth here: past purchases are queried at every
/// launch, and a lapsed subscription simply stops coming back. A field we
/// cannot fill truthfully would be a lie in the type.
@immutable
class ProState {
  const ProState({required this.source, required this.loaded});

  final ProSource source;

  /// False until the store (or the cache) has answered once.
  ///
  /// Kept separate from [isActive] because "not known yet" and "known to be
  /// free" have to look different: a screen that treats the first as the
  /// second shows a padlock for a frame to somebody who paid.
  final bool loaded;

  /// Nothing is known yet — what the controller starts on.
  static const unknown = ProState(source: ProSource.none, loaded: false);

  /// The store has answered, and there is no purchase.
  static const free = ProState(source: ProSource.none, loaded: true);

  bool get isActive => source != ProSource.none;

  ProState copyWith({ProSource? source, bool? loaded}) => ProState(
        source: source ?? this.source,
        loaded: loaded ?? this.loaded,
      );

  @override
  bool operator ==(Object other) =>
      other is ProState && other.source == source && other.loaded == loaded;

  @override
  int get hashCode => Object.hash(source, loaded);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/pro_state_test.dart`
Expected: PASS, 7 tests.

- [ ] **Step 5: Analyze**

Run: `flutter analyze 2>&1 | grep -E "^[[:space:]]*(error|warning)[[:space:]]*[-•]"`
Expected: пусто.

- [ ] **Step 6: Commit**

```bash
git add lib/features/pro/models/pro_state.dart test/pro_state_test.dart
git commit -m "A Pro state that can say it does not know yet"
```

---

### Task 2: `EntitlementSource` и `ProController` поверх подставного источника

Контроллер и интерфейс рождаются вместе: интерфейс без потребителя нечем
проверить, а потребитель без интерфейса не собрать.

**Files:**
- Create: `lib/features/pro/data/entitlement_source.dart`
- Create: `lib/features/pro/data/pro_controller.dart`
- Test: `test/pro_controller_test.dart`

**Interfaces:**
- Consumes: `ProState`, `ProSource`, `ProProduct` из Task 1.
- Produces: `abstract interface class EntitlementSource` с
  `Stream<ProState> get changes`, `Future<void> start()`,
  `Future<void> restore()`, `Future<void> buy(ProProduct product)`,
  `Future<void> dispose()`;
  `final entitlementSourceProvider = Provider<EntitlementSource>(...)`;
  `class ProController extends Notifier<ProState>` с методами
  `Future<void> restore()` и `Future<void> buy(ProProduct)`;
  `final proProvider = NotifierProvider<ProController, ProState>(...)`.

- [ ] **Step 1: Write the failing test**

Создать `test/pro_controller_test.dart`:

```dart
import 'dart:async';

import 'package:cubechat/features/pro/data/entitlement_source.dart';
import 'package:cubechat/features/pro/data/pro_controller.dart';
import 'package:cubechat/features/pro/models/pro_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSource implements EntitlementSource {
  final controller = StreamController<ProState>.broadcast();
  int startCalls = 0;
  int restoreCalls = 0;
  final bought = <ProProduct>[];
  bool disposed = false;

  @override
  Stream<ProState> get changes => controller.stream;

  @override
  Future<void> start() async => startCalls++;

  @override
  Future<void> restore() async => restoreCalls++;

  @override
  Future<void> buy(ProProduct product) async => bought.add(product);

  @override
  Future<void> dispose() async {
    disposed = true;
    await controller.close();
  }
}

ProviderContainer _containerWith(_FakeSource source) {
  final container = ProviderContainer(
    overrides: [entitlementSourceProvider.overrideWithValue(source)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('ProController', () {
    test('starts on unknown rather than on free', () async {
      final source = _FakeSource();
      final container = _containerWith(source);

      expect(container.read(proProvider), equals(ProState.unknown));
    });

    test('starts the source once when it is first read', () async {
      final source = _FakeSource();
      final container = _containerWith(source);

      container.read(proProvider);
      await Future<void>.delayed(Duration.zero);

      expect(source.startCalls, 1);
    });

    test('adopts what the source reports', () async {
      final source = _FakeSource();
      final container = _containerWith(source);
      container.read(proProvider);
      await Future<void>.delayed(Duration.zero);

      source.controller
          .add(const ProState(source: ProSource.lifetime, loaded: true));
      await Future<void>.delayed(Duration.zero);

      expect(container.read(proProvider).isActive, isTrue);
      expect(container.read(proProvider).source, ProSource.lifetime);
    });

    test('keeps the last known answer when the source errors', () async {
      // A dropped store connection is not evidence that the user stopped
      // paying. Falling back to free here is how a paying user gets a padlock
      // because their network blinked.
      final source = _FakeSource();
      final container = _containerWith(source);
      container.read(proProvider);
      await Future<void>.delayed(Duration.zero);

      source.controller
          .add(const ProState(source: ProSource.subscription, loaded: true));
      await Future<void>.delayed(Duration.zero);
      source.controller.addError(StateError('store unreachable'));
      await Future<void>.delayed(Duration.zero);

      expect(container.read(proProvider).isActive, isTrue);
    });

    test('passes a purchase and a restore straight through', () async {
      final source = _FakeSource();
      final container = _containerWith(source);
      final controller = container.read(proProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      await controller.buy(ProProduct.yearly);
      await controller.restore();

      expect(source.bought, [ProProduct.yearly]);
      expect(source.restoreCalls, 1);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/pro_controller_test.dart`
Expected: FAIL — `Target of URI doesn't exist` для обоих новых файлов.

- [ ] **Step 3: Write minimal implementation**

Создать `lib/features/pro/data/entitlement_source.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/pro_state.dart';

/// Where the answer "may this device use Pro" comes from.
///
/// There are two of these by design. This stage has one — the store receipt on
/// the device — and stage two adds blind-signed tokens for the parts the relay
/// has to enforce. Keeping the seam here is what stops the second from being a
/// rewrite of the first.
abstract interface class EntitlementSource {
  /// Everything this source learns, starting with whatever it knows already.
  Stream<ProState> get changes;

  /// Connect, and ask for what is already owned.
  Future<void> start();

  /// Ask the store again for past purchases.
  Future<void> restore();

  /// Begin a purchase. The result arrives on [changes], not as a return value:
  /// a store purchase can finish minutes later, or on another launch.
  Future<void> buy(ProProduct product);

  Future<void> dispose();
}

/// Overridden in tests, and in `main.dart` with the store-backed source.
final entitlementSourceProvider = Provider<EntitlementSource>(
  (ref) => throw UnimplementedError(
    'entitlementSourceProvider must be overridden before proProvider is read',
  ),
);
```

Создать `lib/features/pro/data/pro_controller.dart`:

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/pro_state.dart';
import 'entitlement_source.dart';

/// Whether this device may use Pro, and the two buttons that change it.
///
/// Nothing reads this yet, which is the point of the first step: the billing
/// is proved against the live stores before any feature depends on it.
class ProController extends Notifier<ProState> {
  StreamSubscription<ProState>? _sub;

  @override
  ProState build() {
    final source = ref.watch(entitlementSourceProvider);
    _sub = source.changes.listen(
      (value) => state = value,
      // A dropped store connection is not evidence that somebody stopped
      // paying. The last known answer stands until the store says otherwise.
      onError: (Object e) => debugPrint('Pro entitlement stream failed: $e'),
    );
    ref.onDispose(() {
      unawaited(_sub?.cancel());
    });
    unawaited(source.start());
    return ProState.unknown;
  }

  Future<void> buy(ProProduct product) =>
      ref.read(entitlementSourceProvider).buy(product);

  Future<void> restore() => ref.read(entitlementSourceProvider).restore();
}

final proProvider =
    NotifierProvider<ProController, ProState>(ProController.new);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/pro_controller_test.dart`
Expected: PASS, 5 tests.

- [ ] **Step 5: Analyze and commit**

Run: `flutter analyze 2>&1 | grep -E "^[[:space:]]*(error|warning)[[:space:]]*[-•]"`
Expected: пусто.

```bash
git add lib/features/pro/data test/pro_controller_test.dart
git commit -m "A seam between the right to Pro and where that right came from"
```

---

### Task 3: Ответ переживает перезапуск

Без кэша холодный старт рисует «нет Pro» до того, как стор ответит, и платящий
пользователь видит замок.

**Files:**
- Modify: `lib/features/pro/data/pro_controller.dart`
- Test: `test/pro_cache_test.dart`

**Interfaces:**
- Consumes: `ProController`, `ProState` из Task 2 и Task 1;
  `hiveCipherProvider.openEncryptedBox<dynamic>` и `HiveBoxes.settings` из
  `lib/core/storage/`.
- Produces: `ProController.loaded` — `Future<void>`, разрешается, когда кэш
  прочитан (тот же приём, что у `PrivacySettingsController.loaded`).

- [ ] **Step 1: Write the failing test**

Создать `test/pro_cache_test.dart`:

```dart
import 'dart:async';
import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/storage/hive_init.dart';
import 'package:cubechat/features/pro/data/entitlement_source.dart';
import 'package:cubechat/features/pro/data/pro_controller.dart';
import 'package:cubechat/features/pro/models/pro_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

class _SilentSource implements EntitlementSource {
  final controller = StreamController<ProState>.broadcast();

  @override
  Stream<ProState> get changes => controller.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> restore() async {}
  @override
  Future<void> buy(ProProduct product) async {}
  @override
  Future<void> dispose() async => controller.close();
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_pro_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
  });

  test('a paid answer is still there on the next launch', () async {
    // The store takes a moment to answer on a cold start. Without the cache
    // the interface draws "no Pro" first and corrects itself, which reads as
    // the subscription having vanished.
    final first = ProviderContainer(
      overrides: [
        entitlementSourceProvider.overrideWithValue(_SilentSource()),
      ],
    );
    final firstController = first.read(proProvider.notifier);
    await firstController.loaded;
    await firstController.remember(
      const ProState(source: ProSource.lifetime, loaded: true),
    );
    first.dispose();

    final second = ProviderContainer(
      overrides: [
        entitlementSourceProvider.overrideWithValue(_SilentSource()),
      ],
    );
    addTearDown(second.dispose);
    final secondController = second.read(proProvider.notifier);
    await secondController.loaded;

    expect(second.read(proProvider).source, ProSource.lifetime);
    expect(second.read(proProvider).loaded, isTrue);
  });

  test('an empty cache leaves the state unknown, not free', () async {
    final container = ProviderContainer(
      overrides: [
        entitlementSourceProvider.overrideWithValue(_SilentSource()),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(proProvider.notifier);
    await controller.loaded;

    expect(container.read(proProvider), equals(ProState.unknown));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/pro_cache_test.dart`
Expected: FAIL — `The method 'remember' isn't defined for the class 'ProController'`
и `The getter 'loaded' isn't defined`.

- [ ] **Step 3: Write minimal implementation**

В `lib/features/pro/data/pro_controller.dart` добавить импорты и поля. Импорты
сверху:

```dart
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
```

Внутри `ProController`, рядом с `_sub`:

```dart
  static const _key = 'pro.source';

  Box<dynamic>? _box;
  Future<void>? _loading;

  /// Resolves once the cached answer is in [state]. Anything that decides
  /// something on the strength of Pro has to wait on it; the same shape as
  /// `PrivacySettingsController.loaded`, and for the same reason.
  Future<void> get loaded => _loading ?? Future<void>.value();

  /// True once the store has spoken in this session, so a slow cache read
  /// cannot overwrite a fresher answer.
  bool _answered = false;
```

В `build()` — завести загрузку и пометить ответ стора:

```dart
    _sub = source.changes.listen(
      (value) {
        // `remember` sets the state itself, so it is not set twice here.
        _answered = true;
        unawaited(remember(value));
      },
      onError: (Object e) => debugPrint('Pro entitlement stream failed: $e'),
    );
    unawaited(_loading = _load());
```

И два метода:

```dart
  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      if (_answered) return;
      final name = box.get(_key) as String?;
      if (name == null) return;
      final cached = ProSource.values.where((s) => s.name == name).firstOrNull;
      if (cached == null || cached == ProSource.none) return;
      state = ProState(source: cached, loaded: true);
    } catch (e) {
      debugPrint('Pro cache load failed: $e');
    }
  }

  /// Keep the store's answer for the next cold start.
  Future<void> remember(ProState value) async {
    state = value;
    try {
      await _loading;
      await _box?.put(_key, value.source.name);
    } catch (e) {
      debugPrint('Pro cache persist failed: $e');
    }
  }
```

`firstOrNull` приходит из `package:collection`; если его нет в импортах файла,
заменить на:

```dart
      final cached = ProSource.values
          .cast<ProSource?>()
          .firstWhere((s) => s?.name == name, orElse: () => null);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/pro_cache_test.dart`
Expected: PASS, 2 tests.

- [ ] **Step 5: Run the neighbours to check nothing regressed**

Run: `flutter test test/pro_state_test.dart test/pro_controller_test.dart test/pro_cache_test.dart`
Expected: PASS, 14 tests.

- [ ] **Step 6: Analyze and commit**

```bash
git add lib/features/pro/data/pro_controller.dart test/pro_cache_test.dart
git commit -m "Remember the store's answer so a cold start does not flash a padlock"
```

---

### Task 4: Источник на чеке стора

**Files:**
- Modify: `pubspec.yaml` (добавить `in_app_purchase`)
- Create: `lib/features/pro/data/store_entitlement_source.dart`
- Test: `test/store_entitlement_test.dart`

**Interfaces:**
- Consumes: `EntitlementSource`, `ProState`, `ProSource`, `ProProduct`,
  `proProductFromStoreId`.
- Produces: `ProState proStateFromOwned(Iterable<String> ownedStoreIds)` —
  чистая функция, которую и проверяет тест;
  `class StoreEntitlementSource implements EntitlementSource` — тонкая обвязка
  вокруг неё.

- [ ] **Step 1: Add the dependency**

В `pubspec.yaml`, в секцию `dependencies`, после блока `# Storage`:

```yaml
  # Pro subscription (stage 1). StoreKit 2 on iOS, Play Billing on Android;
  # the receipt stays on the device and no server is told about it.
  in_app_purchase: ^3.2.0
```

Run: `flutter pub get`

- [ ] **Step 2: Write the failing test**

Создать `test/store_entitlement_test.dart`:

```dart
import 'package:cubechat/features/pro/data/store_entitlement_source.dart';
import 'package:cubechat/features/pro/models/pro_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('proStateFromOwned', () {
    test('nothing owned is free, and it is loaded', () {
      // Loaded matters: the store answered, and the answer was no.
      expect(proStateFromOwned(const <String>[]), equals(ProState.free));
    });

    test('a subscription is a subscription', () {
      expect(
        proStateFromOwned(const ['pro.monthly']).source,
        ProSource.subscription,
      );
      expect(
        proStateFromOwned(const ['pro.yearly']).source,
        ProSource.subscription,
      );
    });

    test('lifetime wins over a subscription', () {
      // Somebody who subscribed and later bought lifetime keeps lifetime when
      // the subscription lapses; reporting the subscription would take Pro
      // away from a person who paid for it once and for all.
      expect(
        proStateFromOwned(const ['pro.monthly', 'pro.lifetime']).source,
        ProSource.lifetime,
      );
      expect(
        proStateFromOwned(const ['pro.lifetime', 'pro.yearly']).source,
        ProSource.lifetime,
      );
    });

    test('an id we do not sell is ignored', () {
      expect(proStateFromOwned(const ['pro.something_else']).isActive, isFalse);
    });

    test('always reports itself as loaded', () {
      expect(proStateFromOwned(const ['pro.lifetime']).loaded, isTrue);
      expect(proStateFromOwned(const <String>[]).loaded, isTrue);
    });
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/store_entitlement_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../store_entitlement_source.dart'`.

- [ ] **Step 4: Write minimal implementation**

Создать `lib/features/pro/data/store_entitlement_source.dart`:

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../models/pro_state.dart';
import 'entitlement_source.dart';

/// What the set of owned product ids means.
///
/// Separated from the plugin on purpose: this is the whole of the logic, and
/// it runs in a plain unit test on a machine with no store and no phone.
ProState proStateFromOwned(Iterable<String> ownedStoreIds) {
  var source = ProSource.none;
  for (final id in ownedStoreIds) {
    final product = proProductFromStoreId(id);
    if (product == null) continue;
    // Lifetime outranks a subscription: somebody who has both keeps Pro when
    // the subscription lapses.
    if (product.source == ProSource.lifetime) return const ProState(
        source: ProSource.lifetime,
        loaded: true,
      );
    source = ProSource.subscription;
  }
  return ProState(source: source, loaded: true);
}

/// The store receipt on this device, and nothing else.
///
/// No server is told about the purchase. That is the whole of stage one: what
/// it can gate is what costs nothing to run, and a modified build walking past
/// it costs us nothing either. The parts the relay has to enforce wait for the
/// blind-signed tokens of stage two.
class StoreEntitlementSource implements EntitlementSource {
  StoreEntitlementSource({InAppPurchase? iap})
      : _iap = iap ?? InAppPurchase.instance;

  final InAppPurchase _iap;
  final _out = StreamController<ProState>.broadcast();
  final _owned = <String>{};
  StreamSubscription<List<PurchaseDetails>>? _sub;

  @override
  Stream<ProState> get changes => _out.stream;

  @override
  Future<void> start() async {
    _sub = _iap.purchaseStream.listen(
      _apply,
      onError: (Object e) => _out.addError(e),
    );
    if (!await _iap.isAvailable()) {
      // No store on this device (a desktop build, or a phone without Play
      // services). Not an error, and not a reason to claim Pro.
      _out.add(ProState.free);
      return;
    }
    await restore();
  }

  @override
  Future<void> restore() => _iap.restorePurchases();

  @override
  Future<void> buy(ProProduct product) async {
    final response = await _iap.queryProductDetails({product.storeId});
    final details = response.productDetails
        .where((d) => d.id == product.storeId)
        .firstOrNull;
    if (details == null) {
      _out.addError(StateError('product ${product.storeId} not in the store'));
      return;
    }
    final param = PurchaseParam(productDetails: details);
    // Both the subscription and the lifetime unlock are non-consumable as far
    // as the plugin is concerned: neither is bought twice over.
    await _iap.buyNonConsumable(purchaseParam: param);
  }

  void _apply(List<PurchaseDetails> purchases) {
    for (final p in purchases) {
      final owned = p.status == PurchaseStatus.purchased ||
          p.status == PurchaseStatus.restored;
      if (owned) {
        _owned.add(p.productID);
      } else if (p.status == PurchaseStatus.error) {
        debugPrint('Purchase failed: ${p.error}');
      }
      // Pending and canceled change nothing: the first has not happened yet
      // and the second did not happen.
      if (p.pendingCompletePurchase) {
        unawaited(_iap.completePurchase(p));
      }
    }
    _out.add(proStateFromOwned(_owned));
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    await _out.close();
  }
}
```

Если анализатор ругается на `firstOrNull`, добавить
`import 'package:collection/collection.dart';`.

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/store_entitlement_test.dart`
Expected: PASS, 5 tests.

- [ ] **Step 6: Wire the real source in**

В `lib/main.dart` найти `ProviderScope` и добавить в его `overrides`:

```dart
        entitlementSourceProvider.overrideWithValue(StoreEntitlementSource()),
```

с импортом `package:cubechat/features/pro/data/store_entitlement_source.dart`
и `package:cubechat/features/pro/data/entitlement_source.dart`.

- [ ] **Step 7: Run the whole suite**

Run: `flutter test`
Expected: PASS — 449 существующих плюс 19 новых.

- [ ] **Step 8: Analyze and commit**

```bash
git add pubspec.yaml pubspec.lock lib/features/pro/data/store_entitlement_source.dart lib/main.dart test/store_entitlement_test.dart
git commit -m "Ask the store what this device owns, and keep the answer on it"
```

---

### Task 5: Экран покупки

**Files:**
- Create: `lib/features/pro/presentation/pro_screen.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_uk.arb`
- Test: `test/pro_screen_test.dart`

**Interfaces:**
- Consumes: `proProvider`, `ProProduct`, `ProState`; `GlassCard` из
  `lib/core/widgets/glass_card.dart`; `PillButton` из
  `lib/core/widgets/pill_button.dart`.
- Produces: `class ProScreen extends ConsumerWidget` — без параметров.

- [ ] **Step 1: Add the strings**

В `lib/l10n/app_en.arb`:

```json
"proTitle": "cubechat Pro",
"proBlurb": "The mesh, the encryption and delivery stay free for everyone. Pro pays for what the server costs to run.",
"proMonthly": "Monthly",
"proYearly": "Yearly",
"proLifetime": "Lifetime",
"proRestore": "Restore purchases",
"proActive": "Pro is active on this device",
```

В `lib/l10n/app_uk.arb` — те же ключи с украинским переводом.

Run: `flutter gen-l10n`

- [ ] **Step 2: Write the failing test**

Создать `test/pro_screen_test.dart`. Харнесс `AppLocalizations` скопировать из
`test/chat_search_capture_test.dart`:

```dart
import 'package:cubechat/features/pro/data/entitlement_source.dart';
import 'package:cubechat/features/pro/data/pro_controller.dart';
import 'package:cubechat/features/pro/models/pro_state.dart';
import 'package:cubechat/features/pro/presentation/pro_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The screen is asked which half to draw, and that is what gets pinned.
/// `build()` returns the answer directly and never calls `super.build()`,
/// which would load Hive over it a frame later.
class _Pro extends ProController {
  _Pro(this._value);
  final ProState _value;
  @override
  ProState build() => _value;
}

/// `proProvider` is overridden, so nothing reads the source — but the provider
/// still has to resolve to something rather than throw.
class _IdleSource implements EntitlementSource {
  @override
  Stream<ProState> get changes => const Stream<ProState>.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> restore() async {}
  @override
  Future<void> buy(ProProduct product) async {}
  @override
  Future<void> dispose() async {}
}

Widget _app(ProState value) => ProviderScope(
      overrides: [
        entitlementSourceProvider.overrideWithValue(_IdleSource()),
        proProvider.overrideWith(() => _Pro(value)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ProScreen(),
      ),
    );

void main() {
  testWidgets('offers all three products to somebody without Pro',
      (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(ProState.free));
    await tester.pumpAndSettle();

    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text('Yearly'), findsOneWidget);
    expect(find.text('Lifetime'), findsOneWidget);
    expect(find.text('Restore purchases'), findsOneWidget);
  });

  testWidgets('tells an existing subscriber that Pro is already on',
      (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(const ProState(source: ProSource.lifetime, loaded: true)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pro is active on this device'), findsOneWidget);
  });

  testWidgets('shows no padlock while the store has not answered',
      (tester) async {
    // Unknown is not free. Somebody who paid must not see the sales pitch for
    // a frame on every cold start.
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(ProState.unknown));
    await tester.pumpAndSettle();

    expect(find.text('Monthly'), findsNothing);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/pro_screen_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../pro_screen.dart'`.

- [ ] **Step 4: Write the screen**

Создать `lib/features/pro/presentation/pro_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../l10n/app_localizations.dart';
import '../data/pro_controller.dart';
import '../models/pro_state.dart';

/// What Pro is, and the three ways to buy it.
///
/// Prices are not on this screen yet: they come from the store, and the
/// products do not exist there until they are registered. Names first, sums in
/// the task after.
class ProScreen extends ConsumerWidget {
  const ProScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final pro = ref.watch(proProvider);

    // Not known yet is not the same as no. Drawing the pitch here would show
    // it for a frame on every cold start to somebody who already paid.
    if (!pro.loaded) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(t.proTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (pro.isActive)
            GlassCard(
              child: Text(t.proActive),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(t.proBlurb),
            ),
            // The card is the button: `GlassCard` already takes an `onTap`,
            // and a pill inside a card repeats the product name twice on one
            // row.
            for (final product in ProProduct.values)
              GlassCard(
                margin: const EdgeInsets.only(bottom: 12),
                onTap: () => ref.read(proProvider.notifier).buy(product),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_label(t, product)),
                    const Icon(Icons.chevron_right_rounded),
                  ],
                ),
              ),
            TextButton(
              onPressed: () => ref.read(proProvider.notifier).restore(),
              child: Text(t.proRestore),
            ),
          ],
        ],
      ),
    );
  }

  String _label(AppLocalizations t, ProProduct product) => switch (product) {
        ProProduct.monthly => t.proMonthly,
        ProProduct.yearly => t.proYearly,
        ProProduct.lifetime => t.proLifetime,
      };
}
```

`PillButton` на этом экране не используется — убрать его из импортов, иначе
анализатор отметит неиспользованный импорт.

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/pro_screen_test.dart`
Expected: PASS, 3 tests.

- [ ] **Step 6: Analyze and commit**

```bash
git add lib/features/pro/presentation lib/l10n test/pro_screen_test.dart
git commit -m "A screen that sells Pro and says nothing until the store has answered"
```

---

### Task 6: Вход с экрана профиля

**Files:**
- Modify: `lib/features/profile/presentation/profile_screen.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_uk.arb`
- Test: `test/pro_entry_test.dart`

**Interfaces:**
- Consumes: `ProScreen`, `proProvider`.
- Produces: ничего для последующих задач.

- [ ] **Step 1: Add the string**

`"proEntry": "cubechat Pro"` в оба arb-файла, затем `flutter gen-l10n`.

- [ ] **Step 2: Write the failing test**

Создать `test/pro_entry_test.dart`. Харнесс — тот же, что у
`profile_sections_capture_test.dart`: экран читает настоящие настройки при
сборке, поэтому ему нужны временный Hive и подставные `SharedPreferences`.

```dart
import 'dart:io';

import 'package:cubechat/core/routing/app_router.dart';
import 'package:cubechat/features/profile/presentation/profile_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// Walks nested routes: the screens hang off a shell, not off the top level.
bool _hasPath(List<RouteBase> routes, String path) {
  for (final route in routes) {
    if (route is GoRoute && route.path == path) return true;
    if (_hasPath(route.routes, path)) return true;
  }
  return false;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_pro_entry_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('the profile offers one way in to Pro', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(useMaterial3: true),
          home: const ProfileScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('cubechat Pro'), 120);
    expect(find.text('cubechat Pro'), findsOneWidget);
  });

  test('the route the row pushes actually exists', () {
    // The row above pushes '/pro'. A row pointing at a path nobody registered
    // compiles, passes the widget test, and does nothing on the phone.
    expect(_hasPath(buildRouter().configuration.routes, '/pro'), isTrue);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/pro_entry_test.dart`
Expected: FAIL — обоими тестами: строка не найдена, маршрут не зарегистрирован.

- [ ] **Step 4: Register the route**

В `lib/core/routing/app_router.dart`, рядом с `GoRoute` для `/customize`
(около строки 388), добавить:

```dart
      GoRoute(
        path: '/pro',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) => fadeSlidePage(
          child: const AuroraBackground(child: ProScreen()),
          state: state,
        ),
      ),
```

с импортом `package:cubechat/features/pro/presentation/pro_screen.dart`.

- [ ] **Step 5: Add the row**

В `lib/features/profile/presentation/profile_screen.dart`, рядом с
`_CustomizeRow` (около строки 1780), добавить по её образцу:

```dart
class _ProRow extends StatelessWidget {
  const _ProRow();

  @override
  Widget build(BuildContext context) => _PushRow(
        icon: Icons.workspace_premium_rounded,
        label: AppLocalizations.of(context).proEntry,
        route: '/pro',
      );
}
```

и поставить `const _ProRow(),` в список рядом с
`_CustomizeRow(summary: _customizeSummary(ref, t)),` (около строки 235).

Никаких всплывающих окон, баннеров в переписке и вторых точек входа.

- [ ] **Step 6: Run the whole suite**

Run: `flutter test`
Expected: PASS.

- [ ] **Step 7: Analyze and commit**

```bash
git add lib/features/profile/presentation/profile_screen.dart lib/l10n test/pro_entry_test.dart
git commit -m "One way in to Pro, from the profile and nowhere else"
```

---

## Проверка перед сдачей

- [ ] `flutter test` — зелёный целиком
- [ ] `flutter analyze 2>&1 | grep -E "^[[:space:]]*(error|warning)[[:space:]]*[-•]"` — пусто
- [ ] Ни одна существующая функция не стала платной: `git diff main --stat`
      не содержит правок в `messaging_service.dart`, `theme_controller.dart`,
      `circle_recorder.dart`, `sticker_pack.dart`
- [ ] Товары `pro.monthly`, `pro.yearly`, `pro.lifetime` заведены в обоих
      сторах и покупка проверена в песочнице

## Вне объёма этого плана

Иконка в тон теме, стикер-паки, авто-бэкап, серверная квота — отдельные планы.
Цены из стора на экране покупки — следующая задача после того, как товары
заведены. Сборка APK и подъём `appBuildStamp` — по скиллу `release-build`.
