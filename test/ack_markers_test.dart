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
