@Tags(['golden'])
// Pictures of the redesigned room screen, recorded on the machine that draws
// them. Excluded from CI like every other capture here — fonts rasterise
// differently on the Linux runner and the comparison stops meaning anything.
//
// Record or refresh with:
//   flutter test --tags golden --update-goldens test/channel_info_capture_test.dart
library;

import 'dart:io';

import 'package:cubechat/features/channels/data/channel_controller.dart';
import 'package:cubechat/features/channels/data/channel_roster_controller.dart';
import 'package:cubechat/features/channels/presentation/channel_info_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// Somebody else holds the room, so this phone is a member: no pencil, no
/// settings row, and leaving where the administrator has the wallpaper.
/// The two halves the owner asked for: the room this phone runs, and the room
/// it only belongs to. The seat is handed over rather than claimed, because
/// claiming it mints a keypair — real work a widget test's clock never does.
class _Roster extends ChannelRosterController {
  _Roster({required this.iAmAdmin});

  final bool iAmAdmin;

  @override
  Map<String, Map<String, ChannelMember>> build() {
    // Deliberately not calling super.build(): it loads the roster off Hive and
    // would replace this one a frame later.
    return {
      '#design': {
        'ffffffffffffffff': ChannelMember(
          id: 'ffffffffffffffff',
          name: 'Olena',
          isAdmin: !iAmAdmin,
          lastSeen: DateTime(2026, 9, 16),
        ),
        'aaaaaaaaaaaaaaaa': ChannelMember(
          id: 'aaaaaaaaaaaaaaaa',
          name: 'Taras',
          isAdmin: iAmAdmin,
          isOwner: iAmAdmin,
          lastSeen: DateTime(2026, 9, 16),
        ),
      },
    };
  }

  @override
  Future<ChannelMember> ensureSelf(
    String channel, {
    bool adminWhenFirst = false,
  }) async =>
      state[channel]!['aaaaaaaaaaaaaaaa']!;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_channel_shot_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the encrypted box briefly after close.
    }
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required bool asAdmin,
  }) async {
    // The view, not the surface: the cover is 42% of `MediaQuery.sizeOf`, and
    // a resized surface leaves that at the 800x600 test default — the picture
    // would be a phone-shaped frame with a tablet's proportions inside it.
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        channelRosterControllerProvider.overrideWith(
          () => _Roster(iAmAdmin: asAdmin),
        ),
      ],
    );
    await container.read(channelControllerProvider.notifier).join('#design');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('uk'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChannelInfoScreen(channelName: '#design'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    return container;
  }

  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('the administrator half', (tester) async {
    final container = await pump(tester, asAdmin: true);
    await expectLater(
      find.byType(ChannelInfoScreen),
      matchesGoldenFile('../.codex/design-qa/channel-admin-390x844.png'),
    );
    await finish(tester, container);
  });

  testWidgets('the member half', (tester) async {
    final container = await pump(tester, asAdmin: false);
    await expectLater(
      find.byType(ChannelInfoScreen),
      matchesGoldenFile('../.codex/design-qa/channel-member-390x844.png'),
    );
    await finish(tester, container);
  });
}
