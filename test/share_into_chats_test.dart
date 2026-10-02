import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/features/airdrop/data/share_inbox.dart';
import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/share/presentation/share_into_chats.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:cubechat/l10n/app_localizations_en.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// "Share → CubeChat" opens the forward picker — Saved and every chat — and
/// keeps AirDrop as the row on top when there are files to hand over.
void main() {
  late Directory tempDir;
  final t = AppLocalizationsEn();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    tempDir = await Directory.systemTemp.createTemp('cubechat_share_into_');
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

  Future<void> open(
    WidgetTester tester,
    SharedBundle bundle, {
    required VoidCallback onAirDrop,
  }) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatsProvider.overrideWithValue([
            Chat(
              id: 'aa11',
              peerId: 'aa11',
              peerName: 'Ann',
              lastMessage: '',
              lastTime: DateTime(2026, 10, 2),
              unreadCount: 0,
              isMesh: false,
            ),
          ]),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    shareIntoChats(context, ref, bundle, onAirDrop: onAirDrop),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('files: Saved and the chats, with AirDrop on top',
      (tester) async {
    var airDrop = 0;
    await open(
      tester,
      const SharedBundle(
        files: [SharedFile(path: '/c/a.pdf', name: 'a.pdf', mime: 'x/y')],
      ),
      onAirDrop: () => airDrop++,
    );
    expect(find.text(t.shareIntoTitle), findsOneWidget);
    expect(find.text(t.savedTitle), findsOneWidget);
    expect(find.text('Ann'), findsOneWidget);

    await tester.tap(find.text(t.shareNearbyAirDrop));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(airDrop, 1);
    expect(find.text(t.shareIntoTitle), findsNothing);
  });

  testWidgets('a link: no AirDrop row, there is nothing to hand over',
      (tester) async {
    await open(
      tester,
      const SharedBundle(text: 'https://example.com'),
      onAirDrop: () {},
    );
    expect(find.text(t.shareIntoTitle), findsOneWidget);
    expect(find.text(t.shareNearbyAirDrop), findsNothing);
  });
}
