import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/util/transition_probe.dart';
import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/profile/data/transition_benchmark.dart';
import 'package:cubechat/features/profile/presentation/diagnostics_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// The chat names under "scripted run" on the real Diagnostics screen start a
/// run: the sheet appears and the app leaves for the chat list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    tempDir = await Directory.systemTemp.createTemp('cubechat_bench_button_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    await hiveCipherProvider.wipe();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  tearDown(() => DiagnosticsScreen.developerModeForTest = false);

  testWidgets('tapping a chat name starts the scripted run', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final chat = Chat(
      id: 'a' * 64,
      peerId: 'a' * 64,
      peerName: 'Alice',
      lastMessage: 'hi',
      lastTime: DateTime(2026, 9, 15),
      unreadCount: 0,
      isMesh: false,
    );
    final router = GoRouter(
      initialLocation: '/diagnostics',
      routes: [
        GoRoute(
          path: '/chats',
          builder: (_, __) => const Scaffold(body: Text('list')),
        ),
        GoRoute(
          path: '/chat/:id',
          builder: (_, __) => const Scaffold(body: Text('chat')),
        ),
        GoRoute(
          path: '/diagnostics',
          builder: (_, __) => const DiagnosticsScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [visibleChatsProvider.overrideWith((ref) => [chat])],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // An ordinary visit: the plain log and the button to send it, no tests.
    expect(find.text('Send log to the developer'), findsWidgets);
    expect(find.text('Transitions'), findsNothing);

    // Seven taps on the title, the way Android hides its own.
    for (var i = 0; i < 7; i++) {
      await tester.tap(find.text('Diagnostics'));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Transitions'), findsOneWidget);

    await tester.tap(find.text('Transitions'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('Alice'));
    await tester.pump();
    await tester.tap(find.text('Alice'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(TransitionBenchmark.instance.running, isTrue);
    expect(find.textContaining('hands off'), findsOneWidget);

    // Stop it the way a person would, and let it put everything back.
    await tester.pump(const Duration(seconds: 2));
    await tester.tapAt(const Offset(20, 400));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(TransitionBenchmark.instance.running, isFalse);
    expect(TransitionProbe.instance.armed.value, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
