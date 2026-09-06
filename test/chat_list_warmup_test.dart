// The chat list must be true on the first frame it is drawn on.
//
// Every controller behind it returns an empty collection from `build()` and
// fills it from disk afterwards. That is fine everywhere except at startup,
// where "empty for a moment" is not blankness but a lie: the list renders its
// *empty state*, so a phone with a hundred conversations opened on "no chats
// yet" and then cut — with no entrance, since `AppearOnce` disables the row
// animation in a post-frame callback that had long since run — to the real
// list. Reported twice as a jerk on startup.
//
// `warmChatList` is what startup awaits, behind the launch icon, so that does
// not happen. These tests hold both halves: that it actually finishes the read,
// and that without it the state really is empty (which is the thing that made
// the screen wrong, and the reason the wait is worth its milliseconds).
import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chats/data/chat_list_warmup.dart';
import 'package:cubechat/features/chats/data/pinned_chats_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  const chatId =
      'aa11bb22cc33dd44ee55ff6677889900aa11bb22cc33dd44ee55ff6677889900';

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    tempDir = await Directory.systemTemp.createTemp('cubechat_warmup_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    await hiveCipherProvider.wipe();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can briefly retain a Hive handle after close.
    }
  });

  /// A phone that has been used: one conversation on disk, one pin.
  Future<void> seed() async {
    final container = ProviderContainer();
    final messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;
    messages.append(
      chatId,
      Message(
        id: 'm1',
        chatId: chatId,
        text: 'the message that was already there',
        sentAt: DateTime(2026, 9, 6, 12),
        isMine: false,
      ),
    );
    await messages.flushPending();
    await container.read(pinnedChatsControllerProvider.notifier).pin(chatId);
    container.dispose();
    await settleBackgroundStorage();
  }

  test('the list is on screen at the first frame, not a frame later', () async {
    await seed();

    // A fresh launch: a new container, nothing read yet.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await warmChatList(container);

    // Read synchronously, exactly as the first `build()` of the list does.
    // Nothing is pumped and nothing is awaited between here and the assertion.
    //
    // The summary, not the conversation. Startup deliberately does not wait
    // for history — that is what keeps the launch the same speed whatever the
    // history weighs — so what has to be true here is that the row can be
    // drawn: the preview and the unread badge, both of which come from this.
    final summary = container
        .read(messagesControllerProvider.notifier)
        .summaries[chatId];
    expect(
      summary,
      isNotNull,
      reason: 'the conversation was on disk and the first frame had nothing '
          'to draw it from, which is the frame that renders the empty state',
    );
    expect(summary!.last?.text, 'the message that was already there');
    expect(summary.unreadAfter(null), 1);
    expect(
      container.read(pinnedChatsControllerProvider),
      contains(chatId),
      reason: 'a pin that lands after the first frame reorders the list under '
          'the reader, which is the same jerk in a smaller size',
    );
  });

  test('history still arrives, a moment later', () async {
    await seed();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await warmChatList(container);
    // Nobody waits for this at startup; everything that reads whole
    // conversations does.
    await container.read(messagesControllerProvider.notifier).loaded;

    expect(container.read(messagesControllerProvider)[chatId], hasLength(1));
  });

  test('without the warmup the first read really is empty', () async {
    await seed();

    final container = ProviderContainer();
    addTearDown(container.dispose);

    // The old startup, in one line: build the list and draw it.
    expect(container.read(messagesControllerProvider), isEmpty);
    expect(container.read(pinnedChatsControllerProvider), isEmpty);

    // And it is not that the data is gone — only that it had not arrived.
    await container.read(messagesControllerProvider.notifier).loaded;
    expect(container.read(messagesControllerProvider)[chatId], isNotNull);
    await settleBackgroundStorage();
    expect(container.read(pinnedChatsControllerProvider), contains(chatId));
  });
}
