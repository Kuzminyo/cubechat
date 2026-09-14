import 'dart:io';

import 'package:cubechat/core/theme/app_theme.dart';
import 'package:cubechat/core/transport/nostr/websocket_relay_client.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/chat_screen.dart';
import 'package:cubechat/features/peers/data/typing_controller.dart';
import 'package:cubechat/features/profile/data/relay_settings_controller.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What an open conversation rebuilds when something happens that it does not
/// show, or shows in one place.
///
/// "Chats lag" was the report, and the count was the answer: a 2000-message
/// chat rebuilt 460 widgets - every visible bubble - for a typing notice from
/// somebody in a different chat, because the screen watched whole maps (who is
/// typing anywhere, every session, relay, alias and conversation setting). The
/// same 460 for a delivery tick on a single message, because every rebuild
/// made a new bubble for every row. These budgets are what the fixes bought;
/// a subscription widened again fails here rather than on a phone.
final _peer = 'a' * 64;
final _other = 'b' * 64;

class _FakeMessages extends MessagesController {
  @override
  Map<String, List<Message>> build() {
    final start = DateTime(2026, 9, 1);
    return {
      _peer: [
        for (var i = 0; i < 2000; i++)
          Message(
            id: 'm$i',
            wireId: 'w$i',
            chatId: _peer,
            text: 'message number $i with some words in it',
            sentAt: start.add(Duration(minutes: i)),
            isMine: i.isEven,
          ),
      ],
      _other: const [],
    };
  }
}

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    Hive.init(Directory.systemTemp.createTempSync('rebuilds').path);
  });

  testWidgets('an open chat rebuilds only for what it shows', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    for (final ch in [
      'com.llfbandit.record/messages',
      'plugins.it_nomads.com/flutter_secure_storage',
    ]) {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(ch), (call) async => null);
    }
    final container = ProviderContainer(
      overrides: [messagesControllerProvider.overrideWith(_FakeMessages.new)],
    );

    final counts = <String, int>{};
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      final name = element.widget.runtimeType.toString();
      counts[name] = (counts[name] ?? 0) + 1;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    final open = Stopwatch()..start();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.dark(),
        home: ChatScreen(peerId: _peer, peerLabel: 'Alice'),
      ),
    ));
    await tester.pump();
    open.stop();
    await tester.pump(const Duration(seconds: 1));
    tester.takeException();

    int total() {
      final sum = counts.values.fold<int>(0, (a, b) => a + b);
      return sum;
    }

    int bubbles() => counts['MessageBubble'] ?? 0;

    expect(open.isRunning, isFalse);
    counts.clear();

    container.read(typingControllerProvider.notifier).record(_other);
    await tester.pump();
    expect(total(), lessThanOrEqualTo(2),
        reason: 'somebody typing in another chat is nothing to this one');
    counts.clear();

    container.read(relayStatusProvider.notifier).publish({'wss://x': RelayState.connecting});
    await tester.pump();
    expect(total(), lessThanOrEqualTo(2), reason: 'a relay reconnecting');
    counts.clear();

    container.read(messagesControllerProvider.notifier).append(
          _other,
          Message(
            id: 'o1',
            wireId: 'o1',
            chatId: _other,
            text: 'hi',
            sentAt: DateTime(2026, 9, 14),
            isMine: false,
          ),
        );
    await tester.pump();
    expect(total(), lessThanOrEqualTo(2), reason: 'a message in another chat');
    counts.clear();

    container
        .read(messagesControllerProvider.notifier)
        .updateStatus(_peer, 'm1998', MessageStatus.delivered);
    await tester.pump();
    expect(bubbles(), lessThanOrEqualTo(1),
        reason: 'a tick on one message rebuilds that bubble, not all of them');
    counts.clear();

    container.read(typingControllerProvider.notifier).record(_peer);
    await tester.pump();
    expect(bubbles(), 0,
        reason: 'the header saying "typing" is not a reason to redraw bubbles');
    counts.clear();

    await tester.pumpWidget(const SizedBox());
    // Inside the test, not in a tear-down: the container owns the messaging
    // service's timers, and the binding checks for pending timers before any
    // tear-down runs.
    container.dispose();
    await tester.pump(const Duration(seconds: 10));
    tester.takeException();
  });
}
