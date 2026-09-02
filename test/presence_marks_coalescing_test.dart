import 'dart:io';

import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// The other half of the relay backlog, and the expensive half.
///
/// `markPresent` fires per beacon, and it wrote to an encrypted Hive box each
/// time. One launch log holds twenty-odd marks inside 200 ms, stale by up to
/// twenty-three minutes — twenty writes to disk in the half-second after boot,
/// which is when the app was reported as freezing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_marks_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the encrypted box briefly after close.
    }
  });

  final peer = 'ab' * 32;

  test('a backlog of marks is a couple of changes, not one each', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final known = container.read(knownPeersControllerProvider.notifier);
    await settleBackgroundStorage();

    known.upsert(pubkeyHex: peer, displayName: 'Anonymous');
    await settleBackgroundStorage();

    var notifications = 0;
    container.listen(
      knownPeersControllerProvider,
      (_, __) => notifications++,
      fireImmediately: false,
    );

    final now = DateTime.now();
    // Ascending, which is how a backlog arrives and why every one of them gets
    // past the never-backwards guard.
    for (var i = 0; i < 20; i++) {
      await known.markPresent(peer, at: now.subtract(Duration(seconds: 20 - i)));
    }

    expect(notifications, 1, reason: 'only the leading edge so far');

    await Future<void>.delayed(const Duration(milliseconds: 200));
    await settleBackgroundStorage();

    expect(notifications, 2, reason: 'one more for everything that queued');
  });

  test('the mark that survives is the newest, and it is persisted', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final known = container.read(knownPeersControllerProvider.notifier);
    await settleBackgroundStorage();

    known.upsert(pubkeyHex: peer, displayName: 'Anonymous');
    await settleBackgroundStorage();

    final now = DateTime.now();
    final newest = now.subtract(const Duration(seconds: 1));
    await known.markPresent(peer, at: now.subtract(const Duration(seconds: 5)));
    await known.markPresent(peer, at: now.subtract(const Duration(seconds: 3)));
    await known.markPresent(peer, at: newest);

    await Future<void>.delayed(const Duration(milliseconds: 200));
    await settleBackgroundStorage();

    final stored = container.read(knownPeersControllerProvider)[peer];
    expect(stored?.lastPresenceAt?.millisecondsSinceEpoch,
        newest.millisecondsSinceEpoch);
  });

  test('a single mark is not delayed', () async {
    // The ordinary case has nothing to collapse with and must not wait for the
    // case that does.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final known = container.read(knownPeersControllerProvider.notifier);
    await settleBackgroundStorage();

    known.upsert(pubkeyHex: peer, displayName: 'Anonymous');
    await settleBackgroundStorage();

    final at = DateTime.now();
    await known.markPresent(peer, at: at);

    expect(
      container.read(knownPeersControllerProvider)[peer]?.lastPresenceAt,
      isNotNull,
    );
  });

  test('a wipe is not undone by a queued mark', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final known = container.read(knownPeersControllerProvider.notifier);
    await settleBackgroundStorage();

    known.upsert(pubkeyHex: peer, displayName: 'Anonymous');
    await settleBackgroundStorage();

    final now = DateTime.now();
    await known.markPresent(peer, at: now.subtract(const Duration(seconds: 2)));
    await known.markPresent(peer, at: now.subtract(const Duration(seconds: 1)));
    await known.clear();

    await Future<void>.delayed(const Duration(milliseconds: 200));
    await settleBackgroundStorage();

    expect(container.read(knownPeersControllerProvider), isEmpty);
  });
}
