import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/widgets/tab_page_frame.dart';
import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/chat_search_screen.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/contacts/presentation/contacts_screen.dart';
import 'package:cubechat/features/cube_id/data/known_names_controller.dart';
import 'package:cubechat/features/cube_id/presentation/cube_name_lookup_tile.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

class _FixedNames extends KnownNamesController {
  @override
  Map<String, String> build() => const {'aa11': 'dima'};
}

/// "@dima" typed into Contacts' search found nobody — the filter compared it
/// with display names only — and an @name nobody here has offered no way to
/// go and find them.
void main() {
  late Directory tempDir;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    tempDir = await Directory.systemTemp.createTemp('cubechat_name_search_');
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

  Chat contact(String id, String name) => Chat(
        id: id,
        peerId: id,
        peerName: name,
        lastMessage: '',
        lastTime: DateTime(2026, 10, 1),
        unreadCount: 0,
        isMesh: false,
      );

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          contactChatsProvider.overrideWithValue([
            contact('aa11', 'Дмитро'),
            contact('bb22', 'Ann'),
          ]),
          knownNamesProvider.overrideWith(_FixedNames.new),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: ContactsScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(
      find.descendant(
        of: find.byKey(TabPageFrame.searchKey),
        matching: find.byType(TextField),
      ),
      text,
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('an @name finds the contact found by it', (tester) async {
    await pump(tester);
    await search(tester, '@dima');
    expect(find.text('Дмитро'), findsOneWidget);
    expect(find.text('Ann'), findsNothing);
    // Already here: nothing to look up.
    expect(find.byType(CubeNameLookupTile), findsNothing);
  });

  testWidgets('an @name nobody here has offers to find them', (tester) async {
    await pump(tester);
    await search(tester, '@olga_7');
    expect(find.text('Find @olga_7'), findsOneWidget);

    // A plain name is never sent anywhere.
    await search(tester, 'olga_7');
    expect(find.byType(CubeNameLookupTile), findsNothing);
  });

  testWidgets("chats' search finds by @name too, and offers the unknown one",
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatsProvider.overrideWithValue([
            contact('aa11', 'Дмитро'),
            contact('bb22', 'Ann'),
          ]),
          knownNamesProvider.overrideWith(_FixedNames.new),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChatSearchScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextField), '@dima');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Дмитро'), findsWidgets);
    expect(find.text('Ann'), findsNothing);
    expect(find.byType(CubeNameLookupTile), findsNothing);

    await tester.enterText(find.byType(TextField), '@olga_7');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Find @olga_7'), findsOneWidget);
  });
}
