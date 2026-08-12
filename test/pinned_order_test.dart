import 'dart:io';

import 'package:cubechat/features/chats/data/pinned_chats_controller.dart';
import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

Chat _chat(
  String id, {
  bool pinned = false,
  int rank = -1,
  int minutesAgo = 0,
}) =>
    Chat(
      id: id,
      peerId: id,
      peerName: id,
      lastMessage: '',
      lastTime: DateTime(2026, 1, 1).subtract(Duration(minutes: minutesAgo)),
      unreadCount: 0,
      isMesh: true,
      isOnline: false,
      isPinned: pinned,
      pinRank: rank,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('row order', () {
    test('pinned chats keep the order they were dragged into', () {
      // Deliberately the reverse of both the recency order and the id order:
      // neither must be what decides this.
      final rows = [
        _chat('recent', minutesAgo: 1),
        _chat('second-pin', pinned: true, rank: 1, minutesAgo: 500),
        _chat('older', minutesAgo: 90),
        _chat('first-pin', pinned: true, rank: 0, minutesAgo: 900),
      ]..sort(compareChatRows);

      expect(
        rows.map((c) => c.id).toList(),
        ['first-pin', 'second-pin', 'recent', 'older'],
      );
    });

    test('a message in a pinned chat does not move it', () {
      final before = [
        _chat('a', pinned: true, rank: 0, minutesAgo: 10),
        _chat('b', pinned: true, rank: 1, minutesAgo: 20),
      ]..sort(compareChatRows);
      // b has just been written in — the freshest row in the list.
      final after = [
        _chat('a', pinned: true, rank: 0, minutesAgo: 10),
        _chat('b', pinned: true, rank: 1, minutesAgo: 0),
      ]..sort(compareChatRows);

      expect(before.map((c) => c.id), after.map((c) => c.id));
    });

    test('unpinned chats still sort by recency', () {
      final rows = [
        _chat('old', minutesAgo: 300),
        _chat('new', minutesAgo: 2),
      ]..sort(compareChatRows);

      expect(rows.first.id, 'new');
    });
  });

  group('reorderVisible', () {
    late Directory tempDir;
    late ProviderContainer container;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cubechat_pins_');
      Hive.init(tempDir.path);
      SharedPreferences.setMockInitialValues({});
      container = ProviderContainer();
    });

    tearDown(() async {
      container.dispose();
      await settleBackgroundStorage();
      await Hive.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('moves a pin without disturbing one the list is not showing',
        () async {
      final pins = container.read(pinnedChatsControllerProvider.notifier);
      // Pinning prepends, so this is [c, b, a].
      for (final id in ['a', 'b', 'c']) {
        await pins.pin(id);
      }
      expect(container.read(pinnedChatsControllerProvider), ['c', 'b', 'a']);

      // A filtered list showing only c and a, with a dragged above c. b is not
      // on screen and has no opinion — it keeps the slot between them.
      await pins.reorderVisible(['a', 'c']);

      expect(container.read(pinnedChatsControllerProvider), ['a', 'b', 'c']);
    });

    test('ignores an order containing something that is not pinned', () async {
      final pins = container.read(pinnedChatsControllerProvider.notifier);
      await pins.pin('a');
      await pins.pin('b');

      await pins.reorderVisible(['a', 'ghost']);

      expect(container.read(pinnedChatsControllerProvider), ['b', 'a']);
    });
  });
}
