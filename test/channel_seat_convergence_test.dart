import 'dart:io';

import 'package:cubechat/features/channels/data/channel_roster_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// What the reader's bar and the history offer both wait on.
///
/// Two phones that each typed a room's name each find an empty roster and each
/// hand themselves the seat. Until they agree which of them holds it, both can
/// post — so nobody sees a reader's view — and each refuses the other's backlog
/// for coming from somebody their roster does not have as an administrator.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_seat2_');
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

  const room = '#news';

  test('a guessed seat is still a guess after a restart', () async {
    // The half that is easy to get backwards. "Settled" is what gets written
    // to disk, so its *absence* means a guess — and every seat stored by a
    // build that had no such field was one. Written the other way round, a
    // granted seat would come back provisional on the next launch and the room
    // would be up for grabs again every morning.
    var container = ProviderContainer();
    var roster = container.read(channelRosterControllerProvider.notifier);
    // The box has to be open before anything is written: `_persist` drops the
    // write when it is not, silently, which is a fine way to spend an hour.
    await roster.loaded;
    final me = await roster.ensureSelf(room, adminWhenFirst: true);
    await settleBackgroundStorage();
    container.dispose();

    container = ProviderContainer();
    addTearDown(container.dispose);
    roster = container.read(channelRosterControllerProvider.notifier);
    await roster.loaded;

    expect(roster.isAdmin(room, me.id), isTrue);
    expect(roster.holdsProvisionalSeat(room, me.id), isTrue);
    expect(roster.hasConfirmedAdmin(room), isFalse);
  });

  test('a granted seat is still granted after a restart', () async {
    var container = ProviderContainer();
    var roster = container.read(channelRosterControllerProvider.notifier);
    await roster.loaded;
    await roster.setAdmin(room, 'ab' * 8, true);
    await settleBackgroundStorage();
    container.dispose();

    container = ProviderContainer();
    addTearDown(container.dispose);
    roster = container.read(channelRosterControllerProvider.notifier);
    await roster.loaded;

    expect(
      roster.hasConfirmedAdmin(room),
      isTrue,
      reason: 'somebody said so out loud, and that survives a launch',
    );
  });

  test('the lower fingerprint keeps the room', () async {
    // Both sides run the same comparison on the same two strings, so they land
    // on the same answer whichever claim arrives first.
    const mine = '0f0f0f0f0f0f0f0f';
    const theirs = 'f0f0f0f0f0f0f0f0';

    expect(mine.compareTo(theirs) < 0, isTrue);
    expect(theirs.compareTo(mine) < 0, isFalse);
  });

  test('taking their claim and dropping ours leaves one admin', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final roster = container.read(channelRosterControllerProvider.notifier);
    final me = await roster.ensureSelf(room, adminWhenFirst: true);

    // Exactly what the ingest does when the other fingerprint wins.
    await roster.setAdmin(room, 'ab' * 8, true);
    await roster.setAdmin(room, me.id, false);

    expect(roster.isAdmin(room, me.id), isFalse);
    expect(roster.isAdmin(room, 'ab' * 8), isTrue);
    expect(
      roster.hasConfirmedAdmin(room),
      isTrue,
      reason: 'settled now, so a later guess cannot unseat them',
    );
  });

  test('a settled room ignores a fresh guess', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final roster = container.read(channelRosterControllerProvider.notifier);

    await roster.setAdmin(room, 'ab' * 8, true);

    // The ingest only entertains a self-claim while nobody holds the room on
    // more than their own say-so. This is what stops a newcomer taking a room
    // that already has an owner.
    expect(roster.hasConfirmedAdmin(room), isTrue);
  });
}
