import 'dart:io';

import 'package:cubechat/core/transport/shared_contact.dart';
import 'package:cubechat/features/chat/data/conversation_settings_controller.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/widgets/message_bubble.dart';
/*
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
*/
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_privacy_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold the encrypted box for a moment after close.
    }
  });

  test('auto-delete removes expired messages and keeps recent ones', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final messages = container.read(messagesControllerProvider.notifier);
    final settings =
        container.read(conversationSettingsControllerProvider.notifier);
    await messages.loaded;
    await settings.loaded;

    const chatId = 'chat';
    messages.append(
      chatId,
      Message(
        id: 'old',
        chatId: chatId,
        text: 'old',
        sentAt: DateTime.now().subtract(const Duration(days: 2)),
        isMine: false,
      ),
    );
    messages.append(
      chatId,
      Message(
        id: 'recent',
        chatId: chatId,
        text: 'recent',
        sentAt: DateTime.now().subtract(const Duration(hours: 2)),
        isMine: true,
      ),
    );

    await settings.setAutoDelete(chatId, ChatAutoDeletePeriod.oneDay);

    expect(
      container.read(messagesControllerProvider)[chatId]!.map((m) => m.id),
      ['recent'],
    );
  });

  test('copy restriction is stored per conversation', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final settings =
        container.read(conversationSettingsControllerProvider.notifier);
    await settings.loaded;

    await settings.setRestrictCopying('alice', true);

    expect(settings.forChat('alice').restrictCopying, isTrue);
    expect(settings.forChat('bob').restrictCopying, isFalse);
  });

  test('shared contact payload round-trips and rejects malformed input', () {
    const contact = SharedContact(
      pubkeyHex:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      displayName: 'Alice',
    );

    final decoded = SharedContact.tryParse(contact.encode());

    expect(decoded?.pubkeyHex, contact.pubkeyHex);
    expect(decoded?.displayName, contact.displayName);
    expect(SharedContact.tryParse('not a contact'), isNull);
  });
  test('copy rule blocks copy and forward for a protected chat', () {
    final message = Message(
      id: 'm1',
      chatId: 'alice',
      text: 'private text',
      sentAt: DateTime(2026),
      isMine: false,
    );

    expect(
      messageCanBeCopied(message, copyingRestricted: true),
      isFalse,
    );
    expect(
      messageCanBeForwarded(message, copyingRestricted: true),
      isFalse,
    );
    expect(
      messageCanBeForwarded(message, copyingRestricted: false),
      isTrue,
    );
  });

  /*
  testWidgets('restricted chat hides copy and forward actions', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final settings =
        container.read(conversationSettingsControllerProvider.notifier);
    await settings.loaded;
    await settings.setRestrictCopying('alice', true);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: MessageBubble(
              chatId: 'alice',
              message: Message(
                id: 'm1',
                chatId: 'alice',
                text: 'private text',
                sentAt: DateTime(2026),
                isMine: false,
                wireId: 'aa' * 16,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    await tester.longPress(find.text('private text'));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Copy'), findsNothing);
    expect(find.text('Forward'), findsNothing);
    expect(find.text('Delete'), findsOneWidget);
  });
  */
}
