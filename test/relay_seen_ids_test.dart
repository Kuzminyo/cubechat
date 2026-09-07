import 'dart:io';

import 'package:cubechat/core/transport/nostr/relay_watermark_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// What a relaunch is allowed to make the phone do again.
///
/// The REQ deliberately asks for ten minutes *before* the watermark: a sender
/// whose clock trails ours can stamp an event below a mark we have passed, and
/// the overlap stops that message being skipped. The comment beside it called
/// re-downloading that backlog "cheap and harmless", which is true of a
/// 289-byte text frame and not of a 32 kB media chunk.
///
/// Two consecutive launches from a shipped log: six images and 1.43 MB
/// reassembled, three already on disk; then ten images and 2.33 MB, six
/// already on disk — 1.43 MB, 61% of it, thrown away. The same six hashes both
/// times, and thrown away at the *end*, after every chunk was buffered, the
/// signature checked, the file assembled and SHA-256'd.
///
/// The pool already held these ids in memory to de-duplicate across relays,
/// and the gate that reads them sits above verification. Carrying them across
/// a restart is what turns all of that work into a set lookup.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_seen_');
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

  test('ids survive the restart that used to re-do the work', () async {
    final ids = <String>['aa' * 32, 'bb' * 32, 'cc' * 32];
    await RelayWatermarkStore().saveSeenIds(ids);
    await settleBackgroundStorage();

    final restored = await RelayWatermarkStore().loadSeenIds();
    expect(restored, ids);
  });

  test('a first run has none, and takes the backlog it is offered', () async {
    expect(await RelayWatermarkStore().loadSeenIds(), isEmpty);
    expect(await RelayWatermarkStore().load(), isNull);
  });

  test('they are stored apart from the watermark', () async {
    // Two answers to two questions — how far we got, and which events those
    // were. Sharing a key would make one overwrite the other.
    final store = RelayWatermarkStore();
    await store.save(1757278800);
    await store.saveSeenIds(<String>['dd' * 32]);
    await settleBackgroundStorage();

    final next = RelayWatermarkStore();
    expect(await next.load(), 1757278800);
    expect(await next.loadSeenIds(), <String>['dd' * 32]);
  });

  test('a wipe of the box takes both, since neither outlives the identity',
      () async {
    final store = RelayWatermarkStore();
    await store.save(1757278800);
    await store.saveSeenIds(<String>['ee' * 32]);
    await settleBackgroundStorage();
    // Same box the rest of the settings live in — see the class comment — so
    // an emergency wipe clears these with everything else rather than leaving
    // a phone that remembers which mail it took.
    expect(RelayWatermarkStore.key.startsWith('nostr.'), isTrue);
    expect(RelayWatermarkStore.idsKey.startsWith('nostr.'), isTrue);
    expect(RelayWatermarkStore.key, isNot(RelayWatermarkStore.idsKey));
  });

  test('junk on disk is ignored rather than trusted', () async {
    // The list is read back out of an encrypted box that other code writes to.
    // A non-string entry must not reach the dedup set as one.
    final store = RelayWatermarkStore();
    await store.saveSeenIds(<String>['ff' * 32, '']);
    await settleBackgroundStorage();
    expect(await RelayWatermarkStore().loadSeenIds(), <String>['ff' * 32]);
  });
}
