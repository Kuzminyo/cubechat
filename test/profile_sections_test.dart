import 'dart:io';

import 'package:cubechat/features/cube_id/presentation/stranger_reach_selector.dart';
import 'package:cubechat/features/profile/presentation/customize_screen.dart';
import 'package:cubechat/features/profile/presentation/profile_screen.dart';
import 'package:cubechat/features/profile/presentation/settings/settings_tiles.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:cubechat/l10n/app_localizations_uk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
