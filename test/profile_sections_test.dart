import 'dart:async';
import 'dart:io';

import 'package:cubechat/features/cube_id/presentation/stranger_reach_selector.dart';
import 'package:cubechat/features/moderation/presentation/about_screen.dart';
import 'package:cubechat/features/profile/data/discovery_settings_controller.dart';
import 'package:cubechat/features/profile/data/privacy_settings_controller.dart';
import 'package:cubechat/features/profile/presentation/customize_screen.dart';
import 'package:cubechat/features/profile/presentation/profile_screen.dart';
import 'package:cubechat/features/profile/presentation/settings/settings_tiles.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:cubechat/l10n/app_localizations_en.dart';
import 'package:cubechat/l10n/app_localizations_uk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// The profile's sections, each on its own screen. The settings inside them
/// are the same widgets as before; what is pinned here is that each one is
/// where the spec puts it, and that conditional rows stay conditional.
void main() {
  late Directory tempDir;
  final t = AppLocalizationsUk();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_sections_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
    await tester.binding.setSurfaceSize(const Size(400, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('uk'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(useMaterial3: true),
          home: screen,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('privacy & security holds who-sees-me, reach and protection',
      (tester) async {
    await pumpScreen(tester, const PrivacySectionScreen());

    expect(find.text(t.sectionPrivacy), findsOneWidget);
    for (final title in [
      t.profileLastSeen,
      t.profileReadReceipts,
      t.privacyForwardLinkTitle,
      t.profileMapLocation,
      t.appLockTitle,
      t.filterToggle,
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(find.byType(StrangerReachSelector), findsOneWidget);
    // The section's subheader names the question; the selector does not
    // repeat it underneath.
    expect(find.text(t.strangerReachTitle.toUpperCase()), findsOneWidget);
    expect(find.text(t.strangerReachTitle), findsNothing);
    // The grace delay is a setting for a lock that is on. Off, it is absent.
    expect(find.text(t.appLockGraceTitle), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('notifications & calls on Android: wake, quiet hours, calls',
      (tester) async {
    // flutter_test reports Android unless told otherwise.
    await pumpScreen(tester, const NotificationsSectionScreen());

    expect(find.text(t.sectionNotifications), findsOneWidget);
    for (final title in [
      t.pushWakeTitle,
      t.quietHoursTitle,
      t.privacyCallsTitle,
      t.callDirectTitle,
      t.callFullScreenTitle,
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('on iPhone the Android-only rows are gone and leave no gap',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await pumpScreen(tester, const NotificationsSectionScreen());
      expect(find.text(t.callFullScreenTitle), findsNothing);
      expect(find.text(t.callDirectTitle), findsOneWidget);
      // One pane per subheader: nothing left standing empty.
      expect(
        find.byType(SettingsGroup).evaluate().length,
        find.byType(SettingsSubheader).evaluate().length,
      );

      await pumpScreen(tester, const DataSectionScreen());
      expect(find.text(t.profileBackup), findsOneWidget);
      expect(find.text(t.selfUpdateTitle), findsNothing);
      expect(find.byType(SettingsGroup), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('connection: mesh, transport, background, relays',
      (tester) async {
    await pumpScreen(tester, const ConnectionSectionScreen());

    expect(find.text(t.sectionConnection), findsOneWidget);
    for (final title in [
      t.profileMeshSwitch,
      t.profileTransportMesh,
      t.profileBackground,
      t.relaysTitle,
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('chats & media gathers what a message does and costs',
      (tester) async {
    await pumpScreen(tester, const ChatsSectionScreen());

    expect(find.text(t.sectionChats), findsOneWidget);
    for (final title in [
      t.customizeSwipeTitle,
      'Рядок архіву',
      t.customizeQuickReaction,
      t.customizeCircleAudioTitle,
      t.customizeMediaQualityTitle,
      t.customizeDeferMediaTitle,
      t.customizeTranscribeLanguageTitle,
      t.circleLensTitle,
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('appearance keeps the look and gains the language',
      (tester) async {
    await pumpScreen(tester, const CustomizeScreen());

    expect(find.text(t.sectionAppearance), findsOneWidget);
    expect(find.text(t.customizeBarTitle), findsOneWidget);
    expect(find.text(t.profileGlass), findsOneWidget);
    expect(find.text(t.profileLanguageUk), findsOneWidget);
    expect(find.text(t.profileLanguageEn), findsOneWidget);
    for (final gone in [
      t.customizeSwipeTitle,
      t.customizeMediaQualityTitle,
      t.customizeQuickReaction,
    ]) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    expect(tester.takeException(), isNull);
  });

  group('the profile itself', () {
    Future<GoRouter> pumpProfile(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Widget stub(String name) => Scaffold(body: Text('stub:$name'));
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, __) => const ProfileScreen()),
          for (final p in [
            'cube-id',
            'settings/privacy',
            'settings/notifications',
            'settings/connection',
            'settings/chats',
            'customize',
            'settings/data',
            'contact',
          ])
            GoRoute(path: '/$p', builder: (_, __) => stub(p)),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            locale: const Locale('uk'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark(useMaterial3: true),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      return router;
    }

    testWidgets('eight sections and the wipe row', (tester) async {
      await pumpProfile(tester);
      for (final title in [
        t.cubeIdTitle,
        t.sectionPrivacy,
        t.sectionNotifications,
        t.sectionConnection,
        t.sectionChats,
        t.sectionAppearance,
        t.sectionData,
        t.sectionAbout,
        t.profileEmergencyWipe,
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.byType(SettingsSectionRow), findsNWidgets(9));
      expect(find.byIcon(Icons.fingerprint_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a section row opens its route', (tester) async {
      await pumpProfile(tester);
      await tester.tap(find.text(t.sectionPrivacy));
      // Not pumpAndSettle: the profile keeps a ticker alive (the cover), so
      // it never settles.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('stub:settings/privacy'), findsOneWidget);
    });

    testWidgets('the privacy row says who may write, and follows a change',
        (tester) async {
      await pumpProfile(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProfileScreen)),
      );
      // Not awaited: the state changes at once, and the write behind it waits
      // on a real Hive open that fake time never completes.
      unawaited(
        container
            .read(privacySettingsProvider.notifier)
            .setStrangerReach(StrangerReach.request),
      );
      await tester.pump();
      final row = find.ancestor(
        of: find.text(t.sectionPrivacy),
        matching: find.byType(SettingsSectionRow),
      );
      expect(
        find.descendant(of: row, matching: find.text(t.strangerReachRequest)),
        findsOneWidget,
      );

      unawaited(
        container
            .read(privacySettingsProvider.notifier)
            .setStrangerReach(StrangerReach.none),
      );
      await tester.pump();
      expect(
        find.descendant(of: row, matching: find.text(t.strangerReachNone)),
        findsOneWidget,
      );
    });
  });

  testWidgets('every setting lives in exactly one place', (tester) async {
    // The census. Each setting's title, and the screen the spec puts it on;
    // every screen is pumped and the title must be found once across all of
    // them — a setting lost in the move, or left behind in two places, fails
    // here by name. flutter_test reports Android, so Android's rows count.
    final home = <String, List<String>>{
      'privacy': [
        t.profileLastSeen,
        t.profileReadReceipts,
        t.privacyForwardLinkTitle,
        t.profileDiscoverable,
        t.profileMapLocation,
        t.appLockTitle,
        t.filterToggle,
        t.deadmanTitle,
      ],
      'notifications': [
        t.pushWakeTitle,
        t.quietHoursTitle,
        t.privacyCallsTitle,
        t.callDirectTitle,
        t.callFullScreenTitle,
      ],
      'connection': [
        t.profileMeshSwitch,
        t.profileTransportMesh,
        t.profileBackground,
        t.relaysTitle,
      ],
      'chats': [
        t.customizeSwipeTitle,
        'Рядок архіву',
        t.customizeQuickReaction,
        t.customizeCircleAudioTitle,
        t.circleLensTitle,
        t.customizeMediaQualityTitle,
        t.customizeDeferMediaTitle,
        t.customizeTranscribeLanguageTitle,
      ],
      'appearance': [
        t.profileTheme,
        t.profileScale,
        t.profileGlass,
        t.customizeBarTitle,
        t.profileLanguage,
      ],
      'data': [
        t.storageTitle,
        t.profileFileTransfers,
        t.profileBackup,
        t.phoneTransferTitle,
        t.selfUpdateTitle,
      ],
      'about': [t.diagnosticsTitle],
    };
    final screens = <String, Widget>{
      'privacy': const PrivacySectionScreen(),
      'notifications': const NotificationsSectionScreen(),
      'connection': const ConnectionSectionScreen(),
      'chats': const ChatsSectionScreen(),
      'appearance': const CustomizeScreen(),
      'data': const DataSectionScreen(),
      'about': const AboutScreen(),
      'profile': const ProfileScreen(),
    };

    final seen = <String, List<String>>{};
    for (final entry in screens.entries) {
      await pumpScreen(tester, entry.value);
      for (final title in home.values.expand((titles) => titles)) {
        final n = find.text(title).evaluate().length;
        for (var i = 0; i < n; i++) {
          (seen[title] ??= []).add(entry.key);
        }
      }
    }
    for (final entry in home.entries) {
      for (final title in entry.value) {
        expect(seen[title], [entry.key], reason: '"$title"');
      }
    }
  });

  test('the transcription error points at the section that has the setting',
      () {
    // The voice-to-text language moved from Customize to Chats & media; an
    // error still sending people to "Кастомізація" sends them to a screen
    // that no longer has it.
    final en = AppLocalizationsEn();
    expect(t.chatTranscribeNoLanguage, contains(t.sectionChats));
    expect(en.chatTranscribeNoLanguage, contains(en.sectionChats));
  });

  testWidgets('with the mesh off, discoverable says where the radio is',
      (tester) async {
    // Discoverable is greyed out while the mesh is off. The sentence that
    // explained why was on the mesh switch, which now lives on Connection.
    await pumpScreen(tester, const PrivacySectionScreen());
    expect(find.text(t.profileDiscoverableMeshOff), findsNothing);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(PrivacySectionScreen)),
    );
    unawaited(
      container.read(discoverySettingsProvider.notifier).setMeshEnabled(false),
    );
    await tester.pump();
    expect(find.text(t.profileDiscoverableMeshOff), findsOneWidget);
  });

  testWidgets('About carries the way into Diagnostics', (tester) async {
    await pumpScreen(tester, const AboutScreen());
    expect(find.text(t.diagnosticsTitle), findsOneWidget);
  });

  testWidgets('data & storage: storage, transfers, backup, new phone',
      (tester) async {
    await pumpScreen(tester, const DataSectionScreen());

    expect(find.text(t.sectionData), findsOneWidget);
    for (final title in [
      t.storageTitle,
      t.profileFileTransfers,
      t.profileBackup,
      t.phoneTransferTitle,
      t.selfUpdateTitle,
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(find.byType(SettingsGroup), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
