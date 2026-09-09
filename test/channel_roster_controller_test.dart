import 'dart:io';

import 'package:cubechat/features/channels/data/channel_roster_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_roster_test_');
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
      // Windows can retain a Hive handle very briefly after close.
    }
  });

  test('verified members are ordered with administrators first', () async {
    final roster = container.read(channelRosterControllerProvider.notifier);
    await roster.loaded;
    await roster.record(
      '#team',
      ChannelMember(
        id: '1111111111111111',
        name: 'Alice',
        isAdmin: false,
        lastSeen: DateTime(2026, 8, 3),
      ),
    );
    await roster.record(
      '#team',
      ChannelMember(
        id: '2222222222222222',
        name: 'Bob',
        isAdmin: true,
        lastSeen: DateTime(2026, 8, 3),
      ),
    );

    expect(roster.membersFor('#team').map((member) => member.name),
        ['Bob', 'Alice']);
    expect(roster.isAdmin('#team', '2222222222222222'), isTrue);
  });

  test('administrator role and roster survive a restart', () async {
    final roster = container.read(channelRosterControllerProvider.notifier);
    await roster.loaded;
    await roster.record(
      '#team',
      ChannelMember(
        id: '1111111111111111',
        name: 'Alice',
        isAdmin: false,
        lastSeen: DateTime(2026, 8, 3),
      ),
    );
    await roster.setAdmin('#team', '1111111111111111', true);

    final relaunched = ProviderContainer();
    addTearDown(relaunched.dispose);
    final restored = relaunched.read(channelRosterControllerProvider.notifier);
    await restored.loaded;

    expect(restored.membersFor('#team').single.name, 'Alice');
    expect(restored.isAdmin('#team', '1111111111111111'), isTrue);
  });

  /// Who may close the room, and why it cannot move.
  ///
  /// There is no creation event in this protocol, so ownership is a record of
  /// the first settled administrator rather than a proof of anything. What
  /// matters is that the record does not follow the admin list around: an
  /// owner who appoints an administrator must not become deletable by them.
  group('ownership', () {
    const first = '1111111111111111';
    const second = '2222222222222222';

    test('a fresh room has no owner to name', () async {
      final roster = container.read(channelRosterControllerProvider.notifier);
      await roster.loaded;
      await roster.record(
        '#team',
        ChannelMember(
          id: first,
          name: 'Alice',
          isAdmin: false,
          lastSeen: DateTime(2026, 9, 9),
        ),
      );
      expect(roster.ownerOf('#team'), isNull);
      expect(roster.isOwner('#team', first), isFalse);
    });

    test('the first settled seat takes the room', () async {
      final roster = container.read(channelRosterControllerProvider.notifier);
      await roster.loaded;
      await roster.setAdmin('#team', first, true);
      expect(roster.ownerOf('#team'), first);
    });

    test('a second administrator does not take it', () async {
      final roster = container.read(channelRosterControllerProvider.notifier);
      await roster.loaded;
      await roster.setAdmin('#team', first, true);
      await roster.setAdmin('#team', second, true);
      expect(
        roster.ownerOf('#team'),
        first,
        reason: 'an owner appointing an admin must not hand them the room',
      );
      expect(roster.isOwner('#team', second), isFalse);
    });

    test('and standing down as administrator does not hand it over', () async {
      // The room keeps its owner even when they are no longer running it.
      // Ownership that followed the admin flag would make "close this room"
      // reachable by whoever happened to hold a seat this week.
      final roster = container.read(channelRosterControllerProvider.notifier);
      await roster.loaded;
      await roster.setAdmin('#team', first, true);
      await roster.setAdmin('#team', second, true);
      await roster.setAdmin('#team', first, false);
      expect(roster.ownerOf('#team'), first);
    });

    test('it survives a restart', () async {
      final roster = container.read(channelRosterControllerProvider.notifier);
      await roster.loaded;
      await roster.setAdmin('#team', first, true);
      await settleBackgroundStorage();

      final second = ProviderContainer();
      addTearDown(second.dispose);
      final restored =
          second.read(channelRosterControllerProvider.notifier);
      await restored.loaded;
      expect(restored.ownerOf('#team'), first);
    });
  });
}
