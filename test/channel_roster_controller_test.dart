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
}
