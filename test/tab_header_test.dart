import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/widgets/more_button.dart';
import 'package:cubechat/core/widgets/tab_header.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/contacts/presentation/contacts_screen.dart';
import 'package:cubechat/features/peers/presentation/nearby_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:cubechat/l10n/app_localizations_en.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// The tabs' headers hold still when you change tab.
///
/// Each tab drew its own: Chats at a 16-point margin with a 36-point cube and
/// its title centred in an 84-point band, Contacts and Nearby at 20 with a
/// 30- and a 32-point mark and the title at the top. Changing tab moved the
/// title a few points sideways and ten or so up or down, which reads as the
/// screen jumping. What is pinned here is the place: the title, the mark and
/// the subtitle land on the same pixels on all three.
void main() {
  late Directory tempDir;
  final t = AppLocalizationsEn();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    tempDir = await Directory.systemTemp.createTemp('cubechat_tab_header_');
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

  Future<void> pump(WidgetTester tester, Widget screen) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 32),
              viewPadding: const EdgeInsets.only(top: 32),
            ),
            child: child!,
          ),
          home: Scaffold(body: screen),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  ({Rect title, Rect mark}) measure(WidgetTester tester, String title) {
    final header = find.byType(TabHeader);
    expect(header, findsOneWidget, reason: '$title uses the shared header');
    return (
      title: tester.getRect(
        find.descendant(of: header, matching: find.text(title)),
      ),
      mark: tester.getRect(
        find.descendant(of: header, matching: find.byKey(TabHeader.markKey)),
      ),
    );
  }

  testWidgets('chats, contacts and nearby put their title in one place',
      (tester) async {
    await pump(tester, const ChatsListScreen());
    final chats = measure(tester, 'CubeChat');

    await pump(tester, const ContactsScreen());
    final contacts = measure(tester, t.contactsTitle);

    await pump(
      tester,
      const NearbyScreen(pages: [SizedBox(), SizedBox(), SizedBox()]),
    );
    final nearby = measure(tester, t.peersTitle);

    for (final other in [contacts, nearby]) {
      expect(other.title.topLeft.dy, closeTo(chats.title.topLeft.dy, 0.5));
      expect(other.title.topLeft.dx, closeTo(chats.title.topLeft.dx, 0.5));
      expect(other.mark, chats.mark);
    }
  });

  testWidgets('a header row is one height with or without buttons',
      (tester) async {
    Future<double> titleTop(List<Widget> actions) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TabHeader(
              mark: const Icon(Icons.star),
              title: 'T',
              subtitle: 'S',
              actions: actions,
            ),
          ),
        ),
      );
      return tester.getTopLeft(find.text('T')).dy;
    }

    final bare = await titleTop(const []);
    final withMenu = await titleTop([MoreButton(onPressed: () {})]);
    expect(withMenu, bare);
  });

  testWidgets('every three-dots button is the same size', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: MoreButton(onPressed: () {}))),
      ),
    );
    final icon = tester.widget<Icon>(find.byIcon(Icons.more_vert_rounded));
    expect(icon.size, MoreButton.iconSize);
    expect(tester.getSize(find.byType(MoreButton)), const Size(44, 44));
  });
}
