import 'dart:io';

import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chats/data/saved_messages.dart';
import 'package:cubechat/features/chats/data/saved_tags_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// A tag whose note has been deleted is not a leftover — it is a trap.
///
/// The filter bar is built from the tags in use, so an orphan keeps a chip on
/// screen; tapping it filters the notebook by something no note carries, and
/// every note disappears — including the one written next. Reported as
/// "избранное не работает, не отправляются и не отображаются смс" together
/// with "теги когда удалили смс не пропадают", which is the same fault seen
/// from both ends.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_saved_tags_');
    Hive.init(tempDir.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the encrypted box briefly after close.
    }
  });

  Future<String> writeNote(String text) async {
    await container.read(savedMessagesControllerProvider).saveText(text);
    return container.read(messagesControllerProvider)[savedChatId]!.last.id;
  }

  /// Both stores load off Hive; the tags one reconciles itself once they have.
  Future<void> settle() async {
    await container.read(messagesControllerProvider.notifier).loaded;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('a tag goes when the note it was on is deleted', () async {
    final tags = container.read(savedTagsProvider.notifier);
    await settle();
    final id = await writeNote('the wifi password');
    await tags.setTag(id, '🔑');
    expect(tags.tagsInUse, ['🔑']);

    container
        .read(messagesControllerProvider.notifier)
        .deleteManyLocal(savedChatId, {id});
    await settle();

    expect(
      tags.tagsInUse,
      isEmpty,
      reason: 'a chip in the filter bar that matches nothing empties the '
          'notebook when it is tapped',
    );
  });

  test('a filter loses its tag rather than hiding every note', () async {
    final tags = container.read(savedTagsProvider.notifier);
    await settle();
    final receipt = await writeNote('taxi 240');
    await tags.setTag(receipt, '🧾');
    container.read(savedTagFilterProvider.notifier).toggle('🧾');
    expect(container.read(savedTagFilterProvider), '🧾');

    container
        .read(messagesControllerProvider.notifier)
        .deleteManyLocal(savedChatId, {receipt});
    await settle();

    expect(
      container.read(savedTagFilterProvider),
      isNull,
      reason: 'otherwise the next note written is filtered out of its own '
          'notebook and the chat looks broken',
    );
  });

  test('clearing the notebook takes its tags with it', () async {
    final tags = container.read(savedTagsProvider.notifier);
    await settle();
    final id = await writeNote('the spare key is under the pot');
    await tags.setTag(id, '📍');

    await container
        .read(messagesControllerProvider.notifier)
        .clearForChat(savedChatId);
    await settle();

    expect(tags.state, isEmpty);
  });

  test('a tag for a note that is not in the notebook is dropped', () async {
    // Every delete path at once: whatever happened to the note, a tag whose
    // note is not in the notebook stops being a chip in the filter bar the
    // next time the notebook changes.
    final tags = container.read(savedTagsProvider.notifier);
    await settle();
    await tags.setTag('a-note-that-was-deleted', '🧾');

    await writeNote('anything at all');
    await settle();

    expect(tags.tagsInUse, isEmpty);
  });

  test('orphans left by an older build are dropped on the way in', () async {
    // The tags are persisted and the notes they were on are not coming back,
    // so a phone that has been carrying a dead chip since before any of this
    // has to lose it without being asked to do anything.
    final first = container.read(savedTagsProvider.notifier);
    await settle();
    await first.setTag('a-note-from-a-previous-run', '📍');
    expect(first.tagsInUse, ['📍']);

    final second = ProviderContainer();
    addTearDown(second.dispose);
    final reopened = second.read(savedTagsProvider.notifier);
    await second.read(messagesControllerProvider.notifier).loaded;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(reopened.state, isEmpty);
  });

  test('untagging the last note of a tag clears a filter on it', () async {
    final tags = container.read(savedTagsProvider.notifier);
    await settle();
    final id = await writeNote('call the landlord');
    await tags.setTag(id, '📞');
    container.read(savedTagFilterProvider.notifier).toggle('📞');

    await tags.setTag(id, null);
    await settle();

    expect(container.read(savedTagFilterProvider), isNull);
  });
}
