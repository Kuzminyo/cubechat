import 'dart:io';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/profile/presentation/profile_screen.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/contacts/presentation/contacts_screen.dart';
import 'package:cubechat/features/map/presentation/people_map_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/hive_settle.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_test_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  testWidgets('CubechatApp boots and shows the chats screen title',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 200));

    // English locale is the default — "Chats" should appear as the page title.
    expect(find.text('Chats'), findsWidgets);
  });

  testWidgets('Contacts tab opens the persistent contact list',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('Contacts'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ContactsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('each tab opens its own screen, in the order shown',
      (WidgetTester tester) async {
    // StatefulShellRoute pairs tabs to branches by index, so the list in
    // AppShell and the one in app_router have to move together. Nothing in the
    // analyzer catches a mismatch — it just quietly sends a tab to someone
    // else's screen, which is exactly what reordering them invites.
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mapTileProviderProvider.overrideWithValue(
            NetworkTileProvider(
              cachingProvider: const DisabledMapCachingProvider(),
            ),
          ),
        ],
        child: const CubechatApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));

    // Nearby is left out on purpose: mounting it starts the BLE scanner, and
    // flutter_blue_plus has no implementation in the test VM (which reports
    // itself as Android, so the platform guard lets the call through). Leaving
    // it out costs nothing here — a swapped pair always breaks both ends, so
    // Contacts landing on its own screen is what proves Nearby did too.
    for (final (label, screen) in <(String, Type)>[
      ('Contacts', ContactsScreen),
      ('Map', PeopleMapScreen),
      ('Profile', ProfileScreen),
      ('Chats', ChatsListScreen),
    ]) {
      await tester.tap(find.text(label));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byType(screen),
        findsOneWidget,
        reason: 'the "$label" tab must show $screen',
      );
    }
    expect(tester.takeException(), isNull);
  });
}
