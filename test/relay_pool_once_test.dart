import 'dart:async';
import 'dart:io';

import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/core/util/debug_log.dart';
import 'package:cubechat/features/profile/data/relay_settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// The stored settings say the internet fallback is off — and arrive a moment
/// after the defaults, exactly as the real controller's Hive read does.
class _StoredOff extends RelaySettingsController {
  final Completer<void> _done = Completer<void>();

  @override
  RelaySettings build() {
    Future<void>.delayed(const Duration(milliseconds: 30), () {
      state = const RelaySettings(
        enabled: false,
        urls: RelaySettings.defaultUrls,
      );
      _done.complete();
    });
    return RelaySettings.initial;
  }

  @override
  Future<void> get loaded => _done.future;
}

/// A 2026-09-21 log had `internet fallback on` twice at every launch: a pool
/// stood up on the default settings, and torn down and stood up again a moment
/// later when the stored list arrived. The first pool is built from what was
/// stored now, and only once.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  // The buffer fills only through the debugPrint hook; without it both
  // expectations below would be read off an empty log and pass for nothing.
  setUpAll(DebugLog.install);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_pool_once_');
    Hive.init(tempDir.path);
    DebugLog.instance.clear();
  });

  tearDown(() async {
    await settleBackgroundStorage();
    try {
      await Hive.close();
    } on FileSystemException {
      // The service closes its own boxes on dispose, unawaited.
    }
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds a just-closed box briefly.
    }
  });

  test('launch builds the pool from the stored settings, not the defaults',
      () async {
    final container = ProviderContainer(
      overrides: [
        relaySettingsProvider.overrideWith(_StoredOff.new),
        messagingServiceProvider.overrideWith((ref) {
          final service = MessagingService(ref);
          ref.onDispose(() => unawaited(service.dispose()));
          return service;
        }),
      ],
    );
    addTearDown(container.dispose);
    container.read(messagingServiceProvider);
    // Parallel suites can delay identity setup well beyond 300 ms. Wait for
    // the actual pool decision instead of a wall-clock guess.
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!DebugLog.instance.entries.any(
          (e) => e.text.contains('internet fallback off'),
        ) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    final lines = DebugLog.instance.entries.map((e) => e.text).toList();
    expect(
      lines.where((l) => l.contains('internet fallback on')),
      isEmpty,
      reason: 'the defaults said on; nothing should have been built on them',
    );
    expect(
      lines.where((l) => l.contains('internet fallback off')),
      hasLength(1),
    );
  });
}
