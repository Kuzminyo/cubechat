import 'dart:async';
import 'dart:io';

import 'package:cubechat/features/pro/data/entitlement_source.dart';
import 'package:cubechat/features/pro/data/pro_controller.dart';
import 'package:cubechat/features/pro/models/pro_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

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
  Future<bool> buy(ProProduct product) async {
    bought.add(product);
    return true;
  }

  @override
  Future<Map<ProProduct, String>> prices() async => const {};

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
  // The controller caches its answer in the encrypted settings box, so it
  // needs somewhere to write and a key to write under. Without both, the
  // cipher's "delete and retry" throws into the surrounding zone, and
  // package:test hangs that error on whichever test happens to be running.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('cubechat_pro_ctl_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
  });

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
