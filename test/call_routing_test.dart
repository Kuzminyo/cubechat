import 'dart:io';

import 'package:cubechat/features/profile/data/call_routing_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// Whether a call may take the direct path, which hands the other side this
/// phone's IP address.
///
/// Two things are worth pinning. The default is relay-only, because that is
/// the private answer and a fresh install must give it. And a choice survives a
/// restart — otherwise somebody who turned direct calls off would find them on
/// again, which is the dangerous direction for this particular switch to fail.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_call_routing_');
    Hive.init(tempDir.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    await settleBackgroundStorage();
    container.dispose();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can retain a Hive handle briefly after close.
    }
  });

  test('a fresh install relays every call', () async {
    final routing = container.read(callAllowsDirectProvider.notifier);
    await routing.loaded;
    expect(container.read(callAllowsDirectProvider), isFalse);
  });

  test('choosing direct calls survives a restart', () async {
    final routing = container.read(callAllowsDirectProvider.notifier);
    await routing.loaded;
    await routing.set(true);
    await settleBackgroundStorage();

    final next = ProviderContainer();
    addTearDown(next.dispose);
    final restored = next.read(callAllowsDirectProvider.notifier);
    await restored.loaded;
    expect(next.read(callAllowsDirectProvider), isTrue);
  });

  test('a wipe puts calls back through the relay', () async {
    final routing = container.read(callAllowsDirectProvider.notifier);
    await routing.loaded;
    await routing.set(true);
    await routing.reset();
    expect(container.read(callAllowsDirectProvider), isFalse);
    await settleBackgroundStorage();

    final next = ProviderContainer();
    addTearDown(next.dispose);
    final restored = next.read(callAllowsDirectProvider.notifier);
    await restored.loaded;
    expect(next.read(callAllowsDirectProvider), isFalse);
  });
}
