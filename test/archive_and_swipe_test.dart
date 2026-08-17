import 'dart:io';

import 'package:cubechat/features/chats/data/archived_chats_controller.dart';
import 'package:cubechat/features/chats/data/swipe_action_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

ProviderContainer _fresh() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_archive_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  group('the archive', () {
    test('starts empty and takes chats in and out', () async {
      final container = _fresh();
      final archive =
          container.read(archivedChatsControllerProvider.notifier);

      expect(container.read(archivedChatsControllerProvider), isEmpty);

      await archive.archive('peer-a');
      expect(archive.isArchived('peer-a'), isTrue);
      expect(archive.isArchived('peer-b'), isFalse);

      await archive.unarchive('peer-a');
      expect(archive.isArchived('peer-a'), isFalse);
    });

    test('toggle reports which way it went, so the swipe can say so', () async {
      final container = _fresh();
      final archive =
          container.read(archivedChatsControllerProvider.notifier);

      expect(await archive.toggle('peer-a'), isTrue,
          reason: 'true means it went into the drawer');
      expect(await archive.toggle('peer-a'), isFalse,
          reason: 'and false means it came back out');
      expect(archive.isArchived('peer-a'), isFalse);
    });

    test('archiving twice is not two entries', () async {
      final container = _fresh();
      final archive =
          container.read(archivedChatsControllerProvider.notifier);
      await archive.archive('peer-a');
      await archive.archive('peer-a');
      expect(container.read(archivedChatsControllerProvider), hasLength(1));
    });

    test('Emergency Wipe empties it', () async {
      final container = _fresh();
      final archive =
          container.read(archivedChatsControllerProvider.notifier);
      await archive.archive('peer-a');
      await archive.archive('peer-b');

      await archive.clear();
      expect(container.read(archivedChatsControllerProvider), isEmpty);
    });
  });

  group('the swipe action', () {
    test('defaults to archive — the reason the gesture was asked for', () {
      final container = _fresh();
      expect(container.read(chatSwipeActionProvider), ChatSwipeAction.archive);
    });

    test('remembers what was chosen', () async {
      final container = _fresh();
      await container
          .read(chatSwipeActionProvider.notifier)
          .select(ChatSwipeAction.mute);
      expect(container.read(chatSwipeActionProvider), ChatSwipeAction.mute);
    });

    test('an unknown stored name falls back rather than throwing', () {
      // A build that removes an action must not leave the previous one
      // unopenable on somebody's phone.
      expect(ChatSwipeAction.byName('something-we-dropped'),
          ChatSwipeAction.archive);
      expect(ChatSwipeAction.byName(null), ChatSwipeAction.archive);
      expect(ChatSwipeAction.byName('mute'), ChatSwipeAction.mute);
    });

    test('only deleting asks first', () {
      // Everything else is undone by the same swipe again, which is why it can
      // fire straight from the gesture.
      expect(ChatSwipeAction.delete.confirms, isTrue);
      for (final action in ChatSwipeAction.values) {
        if (action == ChatSwipeAction.delete) continue;
        expect(action.confirms, isFalse, reason: '${action.name} would nag');
      }
    });

    test('every action has a mark and a colour to be recognised by', () {
      // The chip in settings wears the colour of the panel the swipe reveals,
      // so a missing one would be a chip that looks like nothing on the row.
      for (final action in ChatSwipeAction.values) {
        expect(action.icon, isNotNull);
        expect(action.color, isNotNull);
      }
    });
  });
}
