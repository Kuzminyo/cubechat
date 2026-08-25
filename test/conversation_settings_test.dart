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

  group('per-contact privacy exceptions', () {
    test('an entry that only hides something is worth keeping', () {
      // `isDefault` decides whether an entry is written at all and whether a
      // stored one is loaded back. Not counting the hidings would drop the
      // whole of this setting on the next launch — the contact would quietly
      // start seeing the thing again, which is the one failure a privacy
      // switch is not allowed to have.
      const hidden = ConversationSettings(hideAvatar: true);
      expect(hidden.isDefault, isFalse);
      expect(const ConversationSettings(hideLastSeen: true).isDefault, isFalse);
      expect(
        const ConversationSettings(hideReadReceipts: true).isDefault,
        isFalse,
      );
      expect(ConversationSettings.initial.isDefault, isTrue);
    });

    test('the three are independent of each other', () {
      final one = ConversationSettings.initial.copyWith(hideLastSeen: true);
      expect(one.hideLastSeen, isTrue);
      expect(one.hideAvatar, isFalse);
      expect(one.hideReadReceipts, isFalse);
      final two = one.copyWith(hideAvatar: true);
      expect(two.hideLastSeen, isTrue, reason: 'copyWith must not clear it');
      expect(two.hideAvatar, isTrue);
    });

    test('a hiding survives being written and read back', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final settings =
          container.read(conversationSettingsControllerProvider.notifier);
      await settings.loaded;
      await settings.setHideAvatar('alice', true);
      await settings.setHideReadReceipts('alice', true);

      expect(settings.forChat('alice').hideAvatar, isTrue);
      expect(settings.forChat('alice').hideReadReceipts, isTrue);
      expect(settings.forChat('alice').hideLastSeen, isFalse);
      expect(settings.forChat('bob').hideAvatar, isFalse,
          reason: 'an exception is about one person, not the roster');
    });

    test('an exception withholds, and can never hand out what the global '
        'switch refused', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final settings =
          container.read(conversationSettingsControllerProvider.notifier);
      await settings.loaded;

      // Global switches default to sharing, so the exception is what decides.
      expect(settings.sharesAvatarWith('alice'), isTrue);
      await settings.setHideAvatar('alice', true);
      expect(settings.sharesAvatarWith('alice'), isFalse);
      expect(settings.sharesAvatarWith('bob'), isTrue);
    });
  });

  test('switching auto-delete on leaves the history that was already there',
      () async {
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

    await settings.setAutoDelete(chatId, const ChatAutoDelete(24 * 60 * 60));

    // Both survive. This used to assert that 'old' was gone the instant the
    // setting was made, which is the literal reading of "delete after a day"
    // and not what anybody means by it: the switch is understood as "from now
    // on", and turning it on wiped the conversation you were still having.
    expect(
      container.read(messagesControllerProvider)[chatId]!.map((m) => m.id),
      ['old', 'recent'],
    );
  });

  // The sweep itself, driven directly. Going through setAutoDelete cannot
  // express this case: the anchor is stamped `now`, so a message both *after*
  // the switch and already past its hour would need the clock moved, and a test
  // that waits an hour is no test. The rule lives in deleteBefore, so that is
  // what is checked — and the test above pins the anchor setAutoDelete records.
  test('the sweep skips what predates the switch and takes what follows it',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;

    const chatId = 'chat';
    final now = DateTime.now();
    final switchedOn = now.subtract(const Duration(days: 1));

    for (final (id, sentAt) in <(String, DateTime)>[
      ('history', now.subtract(const Duration(days: 7))),
      ('expired', now.subtract(const Duration(hours: 5))),
      ('fresh', now.subtract(const Duration(minutes: 10))),
    ]) {
      messages.append(
        chatId,
        Message(
          id: id,
          chatId: chatId,
          text: id,
          sentAt: sentAt,
          isMine: false,
        ),
      );
    }

    // A one-hour timer, switched on yesterday.
    await messages.deleteBefore(
      chatId,
      now.subtract(const Duration(hours: 1)),
      since: switchedOn,
    );

    expect(
      container.read(messagesControllerProvider)[chatId]!.map((m) => m.id),
      ['history', 'fresh'],
    );
  });

  test('without an anchor the sweep still clears everything expired', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;

    const chatId = 'chat';
    final now = DateTime.now();
    messages.append(
      chatId,
      Message(
        id: 'history',
        chatId: chatId,
        text: 'history',
        sentAt: now.subtract(const Duration(days: 7)),
        isMine: false,
      ),
    );

    // Null `since` is the old behaviour, and what an install that predates the
    // anchor loads. It must not start sparing messages it was already deleting.
    await messages.deleteBefore(chatId, now.subtract(const Duration(hours: 1)));

    expect(container.read(messagesControllerProvider)[chatId], isNull);
  });

  test('turning auto-delete off and on again starts a new window', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final settings =
        container.read(conversationSettingsControllerProvider.notifier);
    await settings.loaded;

    const chatId = 'chat';
    await settings.setAutoDelete(chatId, const ChatAutoDelete(60 * 60));
    final first = settings.forChat(chatId).autoDeleteFrom;
    expect(first, isNotNull);

    // Changing the period keeps the original anchor — a shorter timer must not
    // reach further back than the switch itself ever did.
    await settings.setAutoDelete(chatId, const ChatAutoDelete(60));
    expect(settings.forChat(chatId).autoDeleteFrom, first);

    await settings.setAutoDelete(chatId, ChatAutoDelete.off);
    expect(settings.forChat(chatId).autoDeleteFrom, isNull);

    await settings.setAutoDelete(chatId, const ChatAutoDelete(60 * 60));
    expect(settings.forChat(chatId).autoDeleteFrom, isNot(first));
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

  group("the other side's restriction", () {
    test('binds this device, and neither side can undo the other', () async {
      // The whole bug: the switch used to be enforced only on the phone that
      // threw it — the one side already convinced. The phone that could
      // actually forward the conversation never heard about it.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final settings =
          container.read(conversationSettingsControllerProvider.notifier);
      await settings.loaded;

      await settings.setPeerRestrictsCopying('alice', true);
      expect(settings.forChat('alice').restrictCopying, isFalse,
          reason: 'our own switch was never thrown');
      expect(settings.forChat('alice').copyingRestricted, isTrue);
      expect(settings.forChat('bob').copyingRestricted, isFalse);

      // Ours on and off again: theirs is not ours to clear.
      await settings.setRestrictCopying('alice', true);
      await settings.setRestrictCopying('alice', false);
      expect(settings.forChat('alice').copyingRestricted, isTrue);

      // And theirs going away does not take ours with it.
      await settings.setRestrictCopying('alice', true);
      await settings.setPeerRestrictsCopying('alice', false);
      expect(settings.forChat('alice').copyingRestricted, isTrue);
    });

    test('survives a restart, because the notice is not sent again', () async {
      // There is no acknowledgement on the wire and no guarantee of a repeat,
      // so a request that arrived once has to be kept. Forgetting it on
      // relaunch would quietly hand back Copy and Forward.
      final first = ProviderContainer();
      final settings =
          first.read(conversationSettingsControllerProvider.notifier);
      await settings.loaded;
      await settings.setPeerRestrictsCopying('alice', true);
      first.dispose();

      final second = ProviderContainer();
      addTearDown(second.dispose);
      final reloaded =
          second.read(conversationSettingsControllerProvider.notifier);
      await reloaded.loaded;

      expect(reloaded.forChat('alice').peerRestrictsCopying, isTrue);
      expect(reloaded.forChat('alice').copyingRestricted, isTrue);
    });

    test('takes the same message actions away as our own does', () {
      final message = Message(
        id: 'm1',
        chatId: 'alice',
        text: 'private text',
        sentAt: DateTime(2026),
        isMine: false,
      );
      const peerAsked = ConversationSettings(peerRestrictsCopying: true);

      expect(
        messageCanBeCopied(message,
            copyingRestricted: peerAsked.copyingRestricted),
        isFalse,
      );
      expect(
        messageCanBeForwarded(message,
            copyingRestricted: peerAsked.copyingRestricted),
        isFalse,
      );
    });
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

  group('which road to try first', () {
    // A preference, not a pin. The value only reorders what the send path
    // tries; the tests that matter here are that it is remembered at all and
    // that it survives a restart, because a setting that quietly resets is
    // worse than one that was never offered.
    test('Bluetooth first is the default, and costs nothing to store', () {
      expect(ConversationSettings.initial.preferRelay, isFalse);
      expect(ConversationSettings.initial.isDefault, isTrue);
      expect(
        const ConversationSettings(preferRelay: true).isDefault,
        isFalse,
        reason: 'an entry that only sets this still has to be written',
      );
    });

    test('it does not disturb the privacy exceptions beside it', () {
      final both = ConversationSettings.initial
          .copyWith(hideLastSeen: true, preferRelay: true);
      expect(both.preferRelay, isTrue);
      expect(both.hideLastSeen, isTrue);
      expect(both.copyWith(preferRelay: false).hideLastSeen, isTrue);
    });

    test('the choice survives a restart', () async {
      final chat = 'be' * 32;
      var container = ProviderContainer();
      var settings =
          container.read(conversationSettingsControllerProvider.notifier);
      await settings.loaded;
      await settings.setPreferRelay(chat, true);
      expect(settings.prefersRelay(chat), isTrue);
      await settleBackgroundStorage();
      container.dispose();

      container = ProviderContainer();
      addTearDown(container.dispose);
      settings = container.read(conversationSettingsControllerProvider.notifier);
      await settings.loaded;
      expect(settings.prefersRelay(chat), isTrue);
      expect(
        settings.prefersRelay('cc' * 32),
        isFalse,
        reason: 'it is a per-conversation choice, not a global one',
      );
    });

    test('it can be taken back off', () async {
      final chat = 'ba' * 32;
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final settings =
          container.read(conversationSettingsControllerProvider.notifier);
      await settings.loaded;
      await settings.setPreferRelay(chat, true);
      await settings.setPreferRelay(chat, false);
      expect(settings.prefersRelay(chat), isFalse);
    });

  });

  group('ChatAutoDelete', () {
    test('a setting stored as the old enum name survives the upgrade', () {
      // The worst outcome of moving from an enum to a duration would be an
      // update quietly turning somebody's auto-delete off, so the old names
      // stay readable.
      expect(ChatAutoDelete.fromLegacyName('oneDay').duration,
          const Duration(days: 1));
      expect(ChatAutoDelete.fromLegacyName('sevenDays').duration,
          const Duration(days: 7));
      expect(ChatAutoDelete.fromLegacyName('thirtyDays').duration,
          const Duration(days: 30));
      expect(ChatAutoDelete.fromLegacyName('off'), ChatAutoDelete.off);
      expect(ChatAutoDelete.fromLegacyName(null), ChatAutoDelete.off);
      // An unknown name keeps messages rather than deleting on some guess.
      expect(ChatAutoDelete.fromLegacyName('someFutureValue'),
          ChatAutoDelete.off);
    });

    test('off is off, and every other value has a lifetime', () {
      expect(ChatAutoDelete.off.isOn, isFalse);
      expect(ChatAutoDelete.off.duration, isNull);
      expect(const ChatAutoDelete(-5).duration, isNull,
          reason: 'a mangled store must not become an instant purge');
      expect(const ChatAutoDelete(90).duration, const Duration(seconds: 90));
      expect(ChatAutoDelete.presets.first, ChatAutoDelete.off);
    });
  });
}
