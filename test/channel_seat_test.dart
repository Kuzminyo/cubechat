import 'dart:io';

import 'package:cubechat/features/channels/data/channel_roster_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// Two phones, one room, and no way to tell who got there first.
///
/// Joining a channel is deriving a key from a name, so both people who type it
/// start with an empty roster and both hand themselves the seat — and then both
/// refuse the other's claim, because a claim used to be accepted only on a room
/// with nobody in it. Both were administrators of the same channel, which is
/// why nobody ever saw a reader's view of one: everyone could post.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_seat_');
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

  ChannelRosterController rosterOf(ProviderContainer c) =>
      c.read(channelRosterControllerProvider.notifier);

  test('a seat handed out by an empty roster is not a confirmed one', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final roster = rosterOf(container);

    final me = await roster.ensureSelf(room, adminWhenFirst: true);

    expect(roster.isAdmin(room, me.id), isTrue);
    expect(
      roster.hasConfirmedAdmin(room),
      isFalse,
      reason: 'nobody told us; we guessed, and a guess can be given up',
    );
    expect(roster.holdsProvisionalSeat(room, me.id), isTrue);
  });

  test('a seat granted by somebody else is confirmed and stays', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final roster = rosterOf(container);

    await roster.record(
      room,
      ChannelMember(
        id: 'ab' * 8,
        name: 'Anna',
        isAdmin: false,
        lastSeen: DateTime.now(),
      ),
    );
    await roster.setAdmin(room, 'ab' * 8, true);

    expect(roster.hasConfirmedAdmin(room), isTrue);
    expect(roster.holdsProvisionalSeat(room, 'ab' * 8), isFalse);
  });

  test('standing down leaves a plain member, not a half-admin', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final roster = rosterOf(container);
    final me = await roster.ensureSelf(room, adminWhenFirst: true);

    // What the ingest does when the other phone's fingerprint wins the
    // tie-break: take theirs, drop ours.
    await roster.setAdmin(room, 'ff' * 8, true);
    await roster.setAdmin(room, me.id, false);

    expect(roster.isAdmin(room, me.id), isFalse);
    expect(roster.holdsProvisionalSeat(room, me.id), isFalse);
    expect(roster.hasConfirmedAdmin(room), isTrue);
  });

  test('a message from a removed member does not revive them', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final roster = rosterOf(container);

    await roster.moderate(room, memberId: 'cd' * 8, removed: true);
    // Every frame from them runs through `record`, which is where a removal
    // used to be undone by the next thing they said.
    await roster.record(
      room,
      ChannelMember(
        id: 'cd' * 8,
        name: 'Loud',
        isAdmin: false,
        lastSeen: DateTime.now(),
      ),
    );

    expect(roster.canPost(room, 'cd' * 8), isFalse);
    expect(roster.membersFor(room).map((m) => m.id), isNot(contains('cd' * 8)));
  });

  test('a mute expires on its own', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final roster = rosterOf(container);

    await roster.moderate(
      room,
      memberId: 'ef' * 8,
      removed: false,
      mutedUntil: DateTime.now().subtract(const Duration(minutes: 1)),
    );

    expect(
      roster.canPost(room, 'ef' * 8),
      isTrue,
      reason: 'the deadline is compared against the clock, not swept',
    );
  });
}
