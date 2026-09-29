import 'dart:io';

import 'package:cubechat/features/chats/data/message_requests_controller.dart';
import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/chats/presentation/requests_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

class _FakeRequests extends MessageRequestsController {
  final accepted = <String>[];

  @override
  MessageRequests build() => const MessageRequests(pending: {'aa'});

  @override
  Future<void> accept(String peer) async => accepted.add(peer);
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_requests_ui_');
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

  Widget app(List<Chat> chats, _FakeRequests fake) => ProviderScope(
        overrides: [
          requestChatsProvider.overrideWithValue(chats),
          messageRequestsProvider.overrideWith(() => fake),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const RequestsScreen(),
        ),
      );

  testWidgets('a request shows its three actions, and Accept lets them in',
      (tester) async {
    final fake = _FakeRequests();
    await tester.pumpWidget(
      app([
        Chat(
          id: 'aa',
          peerId: 'aa',
          peerName: 'Stranger',
          lastMessage: 'hi',
          lastTime: DateTime(2026, 9, 29),
          unreadCount: 1,
          isMesh: false,
        ),
      ], fake),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Stranger'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Block'), findsOneWidget);
    await tester.tap(find.text('Accept'));
    await tester.pump();
    expect(fake.accepted, ['aa']);
  });

  testWidgets('no requests says so', (tester) async {
    await tester.pumpWidget(app(const [], _FakeRequests()));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('No requests'), findsOneWidget);
  });
}
