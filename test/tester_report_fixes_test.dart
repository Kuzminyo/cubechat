import 'dart:io';

import 'package:cubechat/features/channels/data/channel_roster_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chats/data/favorites_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// Regressions from a round of field testing, each of which was silent: the
/// code did something reasonable-looking and the user got the wrong outcome.
/// None of them would have shown up as a crash, so none of them would have been
/// caught by anything already here.
void main() {
  // The roster persists through an encrypted Hive box, which reads its key over
  // a platform channel — without a binding it falls back to a session key and
  // says so, and without Hive.init it has nowhere to write.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a photo caption', () {
    Message photo(String text) => Message(
          id: 'm1',
          chatId: 'peer',
          text: text,
          sentAt: DateTime(2026, 8, 8),
          isMine: false,
          status: MessageStatus.delivered,
          kind: MessageKind.image,
          imagePath: '/tmp/p.jpg',
        );

    test('is whatever was typed under the picture', () {
      expect(photo('на море').imageCaption, 'на море');
    });

    // The field doubles as where a mime type lands when nothing was typed, so
    // the caption is only a caption when it does not look like one of those.
    // Rendering "image/jpeg" under every uncaptioned photo would be the same
    // bug wearing the opposite sign.
    test('is absent when the field is carrying a mime type instead', () {
      expect(photo('image/jpeg').imageCaption, isNull);
      expect(photo('audio/aac').imageCaption, isNull);
    });

    test('is absent when nothing was typed', () {
      expect(photo('').imageCaption, isNull);
      expect(photo('   ').imageCaption, isNull);
    });

    test('keeps text that merely mentions a slash', () {
      expect(photo('9/10 would go again').imageCaption, '9/10 would go again');
    });
  });

  group('a channel with nobody in charge', () {
    late Directory tempDir;
    late ProviderContainer container;
    late ChannelRosterController roster;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cubechat_roster_test_');
      Hive.init(tempDir.path);
      container = ProviderContainer();
      roster = container.read(channelRosterControllerProvider.notifier);
    });

    tearDown(() async {
      await settleBackgroundStorage();
      container.dispose();
      await Hive.close();
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows holds the Hive files briefly after close.
      }
    });

    ChannelMember member(String id, {required bool admin}) => ChannelMember(
          id: id,
          name: id,
          isAdmin: admin,
          lastSeen: DateTime(2026, 8, 8),
        );

    // The reported bug: two people in a room, each told that only an admin may
    // change the picture and the topic, and no way to appoint one because
    // appointing is itself an admin action. Admin was only ever granted to
    // whoever opened the info screen while the roster still happened to be
    // empty, and the roster fills from other people's messages.
    test('is reported as having no admin', () async {
      await roster.record('#room', member('aaa', admin: false));
      await roster.record('#room', member('bbb', admin: false));
      expect(roster.hasAdmin('#room'), isFalse);
    });

    test('is reported as owned once somebody is an admin', () async {
      await roster.record('#room', member('aaa', admin: false));
      await roster.record('#room', member('bbb', admin: true));
      expect(roster.hasAdmin('#room'), isTrue);
    });

    test('a room nobody has joined has no admin either', () {
      expect(roster.hasAdmin('#empty'), isFalse);
    });

    // record() merges rather than replaces, so a member who is already an admin
    // does not lose it when a later frame from them says otherwise.
    test('does not lose an admin to a later plain sighting', () async {
      await roster.record('#room', member('aaa', admin: true));
      await roster.record('#room', member('aaa', admin: false));
      expect(roster.isAdmin('#room', 'aaa'), isTrue);
      expect(roster.hasAdmin('#room'), isTrue);
    });
  });

  group('favourite order', () {
    late Directory tempDir;
    late ProviderContainer container;
    late FavoritesController favorites;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cubechat_fav_test_');
      Hive.init(tempDir.path);
      container = ProviderContainer();
      favorites = container.read(favoritesControllerProvider.notifier);
    });

    tearDown(() async {
      await settleBackgroundStorage();
      container.dispose();
      await Hive.close();
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows holds the Hive files briefly after close.
      }
    });

    Future<void> star(List<String> ids) async {
      // toggle() puts each new favourite first, so starring a, b, c leaves
      // c, b, a — star them backwards to end up with a, b, c.
      for (final id in ids.reversed) {
        await favorites.toggle(id);
      }
    }

    test('starring puts the newest first', () async {
      await favorites.toggle('a');
      await favorites.toggle('b');
      expect(container.read(favoritesControllerProvider), ['b', 'a']);
    });

    // ReorderableListView reports the destination as an index into the list
    // *before* the dragged row was taken out, so moving downward is off by one
    // unless it is corrected. Both directions are checked because getting one
    // right and the other wrong is the usual outcome.
    test('dragging downward lands where it was dropped', () async {
      await star(['a', 'b', 'c']);
      await favorites.reorder(0, 2);
      expect(container.read(favoritesControllerProvider), ['b', 'a', 'c']);
    });

    test('dragging to the end lands at the end', () async {
      await star(['a', 'b', 'c']);
      await favorites.reorder(0, 3);
      expect(container.read(favoritesControllerProvider), ['b', 'c', 'a']);
    });

    test('dragging upward lands where it was dropped', () async {
      await star(['a', 'b', 'c']);
      await favorites.reorder(2, 0);
      expect(container.read(favoritesControllerProvider), ['c', 'a', 'b']);
    });

    test('an out-of-range drag changes nothing', () async {
      await star(['a', 'b']);
      await favorites.reorder(5, 0);
      expect(container.read(favoritesControllerProvider), ['a', 'b']);
    });

    test('unstarring takes it out of the order', () async {
      await star(['a', 'b', 'c']);
      await favorites.toggle('b');
      expect(container.read(favoritesControllerProvider), ['a', 'c']);
    });
  });
}
