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
  // The settings box is encrypted, and the key comes from the secure store.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
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
