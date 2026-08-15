import 'dart:io';

import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/widgets/chat_tile.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

Chat _chat({bool muted = false, int autoDeleteSeconds = 0}) => Chat(
      id: 'abc',
      peerId: 'abc',
      peerName: 'Kim',
      lastMessage: 'hi',
      lastTime: DateTime(2026, 1, 1),
      unreadCount: 0,
      isMesh: true,
      isOnline: false,
      isMuted: muted,
      autoDeleteSeconds: autoDeleteSeconds,
    );

Future<void> _pumpTile(WidgetTester tester, Chat chat) => tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ChatTile(chat: chat)),
        ),
      ),
    );

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_tile_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('a silenced chat says so next to the name', (tester) async {
    await _pumpTile(tester, _chat());
    await tester.pump();
    expect(find.byIcon(Icons.notifications_off_rounded), findsNothing);

    await _pumpTile(tester, _chat(muted: true));
    await tester.pump();
    expect(find.byIcon(Icons.notifications_off_rounded), findsOneWidget);
  });

  testWidgets('a chat that expires wears a timer on its avatar',
      (tester) async {
    await _pumpTile(tester, _chat());
    await tester.pump();
    expect(find.byIcon(Icons.timer_rounded), findsNothing);

    await _pumpTile(tester, _chat(autoDeleteSeconds: 3600));
    await tester.pump();
    expect(find.byIcon(Icons.timer_rounded), findsOneWidget);
  });
}
