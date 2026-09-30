import 'dart:io';

import 'package:cubechat/core/theme/app_theme.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/chat_screen.dart';
import 'package:cubechat/features/chats/data/read_markers_controller.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:cubechat/l10n/app_localizations_en.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "New messages" above the first thing that arrived since the chat was last
/// read, and the chat opening on it — so a long run of new messages is read
/// from its start instead of from the bottom up.
final _peer = 'a' * 64;
final _start = DateTime(2026, 9, 1);

class _Messages extends MessagesController {
  @override
  Map<String, List<Message>> build() => {
        _peer: [
          for (var i = 0; i < 80; i++)
            Message(
              id: 'm$i',
              wireId: 'w$i',
              chatId: _peer,
              text: 'message $i',
              sentAt: _start.add(Duration(minutes: i)),
              // Mine up to 30, then only theirs: a long run of new messages.
              isMine: i < 30 && i.isEven,
            ),
        ],
      };
}

class _ReadUpTo extends ReadMarkersController {
  _ReadUpTo(this.at);

  final DateTime? at;

  @override
  Map<String, DateTime> build() =>
      at == null ? const {} : {_peer: at!};
}

void main() {
  final t = AppLocalizationsEn();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    Hive.init(Directory.systemTemp.createTempSync('unread_divider').path);
  });

  /// Inside the test, not in a tear-down: the container owns the messaging
  /// service's timers, and the binding checks for pending timers before any
  /// tear-down runs (the same as chat_rebuild_budget_test).
  Future<void> close(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(seconds: 10));
    tester.takeException();
  }

  Future<ProviderContainer> open(WidgetTester tester, DateTime? readUpTo) async {
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
      overrides: [
        messagesControllerProvider.overrideWith(_Messages.new),
        readMarkersControllerProvider.overrideWith(() => _ReadUpTo(readUpTo)),
      ],
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.dark(),
        home: ChatScreen(peerId: _peer, peerLabel: 'Alice'),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    tester.takeException();
    return container;
  }

  testWidgets('the line sits above the first new message, and the chat '
      'opens on it', (tester) async {
    // Read up to message 40: 41 onwards is new.
    final container =
        await open(tester, _start.add(const Duration(minutes: 40)));

    final divider = find.text(t.chatUnreadDivider);
    expect(divider, findsOneWidget);
    // On screen, not somewhere up the history: the chat opened here rather
    // than at the bottom, 39 messages further down.
    expect(divider.hitTestable(), findsOneWidget);
    final first = find.text('message 41');
    expect(first, findsOneWidget);
    expect(
      tester.getBottomLeft(divider).dy,
      lessThanOrEqualTo(tester.getTopLeft(first).dy),
      reason: 'the line goes above the first new message',
    );
    await close(tester, container);
  });

  testWidgets('nothing new: no line, and the chat is at the bottom',
      (tester) async {
    final container =
        await open(tester, _start.add(const Duration(minutes: 100)));
    expect(find.text(t.chatUnreadDivider), findsNothing);
    expect(find.text('message 79'), findsOneWidget);
    await close(tester, container);
  });
}
