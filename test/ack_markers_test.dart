import 'dart:io';

import 'package:cubechat/features/chats/data/read_markers_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// How far each chat's read receipts have been *sent*, as opposed to how far it
/// has been read.
///
/// The set that used to answer this lived only in memory, so every launch
/// re-acknowledged every message in every chat — measured at 144 receipts in
/// twelve relay frames for one conversation inside a second and a half, which
/// is the freeze on cold start.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_acks_');
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

  final chat = 'ac' * 32;

  test('the marker survives a restart, which is the whole point', () async {
    final at = DateTime(2026, 8, 25, 17, 53);
    var container = ProviderContainer();
    var acks = container.read(ackMarkersControllerProvider.notifier);
    await acks.markAcked(chat, at);
    await settleBackgroundStorage();
    container.dispose();

    container = ProviderContainer();
    addTearDown(container.dispose);
    acks = container.read(ackMarkersControllerProvider.notifier);
    // The load is async and receipts go out on chat open, which can beat a disk
    // read — so this is the same settle the app relies on.
    await settleBackgroundStorage();
    expect(acks.ackedUpTo(chat), at);
  });

  test('both markers can be waited for, which is what stops the storm',
      () async {
    // The sweep reads these two together — how far the person has read, and
    // how far that has been reported — and it runs when a relay connects,
    // about a second after launch, while the boxes are still opening. Loaded
    // out of step they say the worst possible thing: everything read, nothing
    // acknowledged, so acknowledge the whole conversation again. Sixteen relay
    // publishes and two seconds of work, on every launch, measured on a phone
    // with about two hundred messages in one chat.
    //
    // The ack marker had `loaded` and the read marker did not, and nothing
    // awaited either. Both have it now, and this is the guarantee the sweep
    // leans on: after awaiting, what was on disk is in the state.
    final at = DateTime(2026, 9, 4, 19, 33);
    var container = ProviderContainer();
    await container.read(readMarkersControllerProvider.notifier).markRead(
          chat,
          at: at,
        );
    await container.read(ackMarkersControllerProvider.notifier).markAcked(
          chat,
          at,
        );
    await settleBackgroundStorage();
    container.dispose();

    container = ProviderContainer();
    addTearDown(container.dispose);
    final reads = container.read(readMarkersControllerProvider.notifier);
    final acks = container.read(ackMarkersControllerProvider.notifier);
    // No settle: the awaits below are the whole mechanism under test.
    await reads.loaded;
    await acks.loaded;

    expect(container.read(readMarkersControllerProvider)[chat], at);
    expect(
      acks.ackedUpTo(chat),
      at,
      reason: 'read without waiting, this is null and everything is re-acked',
    );
  });

  test('it never moves backwards', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final acks = container.read(ackMarkersControllerProvider.notifier);
    final later = DateTime(2026, 8, 25, 18);
    await acks.markAcked(chat, later);
    await acks.markAcked(chat, DateTime(2026, 8, 25, 17));
    expect(
      acks.ackedUpTo(chat),
      later,
      reason: 'a slice that went out cannot un-go',
    );
  });

  test('it is per chat, and unknown chats have no marker', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final acks = container.read(ackMarkersControllerProvider.notifier);
    await acks.markAcked(chat, DateTime(2026));
    expect(acks.ackedUpTo('ba' * 32), isNull);
  });

  test('forgetting a chat forgets its marker', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final acks = container.read(ackMarkersControllerProvider.notifier);
    await acks.markAcked(chat, DateTime(2026));
    await acks.forget(chat);
    expect(acks.ackedUpTo(chat), isNull);
  });

  test('a wipe leaves nothing behind', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final acks = container.read(ackMarkersControllerProvider.notifier);
    await acks.markAcked(chat, DateTime(2026));
    await acks.clear();
    expect(container.read(ackMarkersControllerProvider), isEmpty);
  });

  group('the exact record beside the watermark', () {
    // The watermark alone means "older than the last thing acknowledged,
    // therefore already acknowledged", which holds only if messages arrive in
    // the order they were sent. Since 956 they carry the sender's clock, so
    // anything held on a relay lands stamped older than things already
    // acknowledged. Four stickers sent at 21:12:03 reached the other phone at
    // 21:14:35 after two restarts: chat opened, four banners cleared, one
    // receipt sent. The other three were not late, they were unreachable.

    test('an id acknowledged is remembered across a restart', () async {
      final wire = 'ab' * 32;
      var container = ProviderContainer();
      await container
          .read(ackMarkersControllerProvider.notifier)
          .markIdsAcked({wire: DateTime(2026, 9, 7, 21, 12, 3)});
      await settleBackgroundStorage();
      container.dispose();

      container = ProviderContainer();
      addTearDown(container.dispose);
      final acks = container.read(ackMarkersControllerProvider.notifier);
      await acks.loaded;
      expect(acks.hasAcked(wire), isTrue);
    });

    test('an unacknowledged id below the watermark is still reachable',
        () async {
      // The reported bug, in the smallest form that shows it.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final acks = container.read(ackMarkersControllerProvider.notifier);

      final late = 'cd' * 32;
      await acks.markAcked(chat, DateTime(2026, 9, 7, 21, 13, 35));
      await acks.markIdsAcked({'ef' * 32: DateTime(2026, 9, 7, 21, 13, 35)});

      expect(acks.hasAcked(late), isFalse,
          reason: 'never sent, so it must not read as sent');
      expect(acks.ackCoverFrom, isNull,
          reason: 'under the cap the record answers for everything, so the '
              'watermark never gets to overrule it');
    });

    test('the record is capped, and says how far back it still answers',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final acks = container.read(ackMarkersControllerProvider.notifier);

      final base = DateTime(2026, 9, 7, 12);
      await acks.markIdsAcked({
        for (var i = 0; i < 600; i++)
          i.toRadixString(16).padLeft(64, '0'): base.add(Duration(minutes: i)),
      });

      // Oldest hundred evicted; the survivors start at minute 100.
      expect(acks.hasAcked('0' * 64), isFalse);
      expect(acks.hasAcked(599.toRadixString(16).padLeft(64, '0')), isTrue);
      expect(acks.ackCoverFrom, base.add(const Duration(minutes: 100)),
          reason: 'beyond this the watermark takes over, which is what keeps '
              'the cold-start storm fixed');
    });

    test('a wipe takes the ids too', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final acks = container.read(ackMarkersControllerProvider.notifier);
      await acks.markIdsAcked({'ab' * 32: DateTime(2026)});
      await acks.clear();
      expect(acks.hasAcked('ab' * 32), isFalse);
    });
  });

  test('it is a different marker from the read one', () async {
    // They answer different questions and must not share storage: the read
    // marker decides the unread badge, this one decides what the other phone
    // has already been told.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container
        .read(readMarkersControllerProvider.notifier)
        .markRead(chat, at: DateTime(2026, 8, 25, 18));
    expect(container.read(ackMarkersControllerProvider)[chat], isNull);
  });
}
