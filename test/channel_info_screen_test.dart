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

const _me = 'aaaaaaaaaaaaaaaa';
const _olena = 'ffffffffffffffff';

/// A roster this phone runs, and one it only belongs to.
///
/// The real seat is claimed in `initState` against a freshly minted keypair,
/// which means secure storage and a file — real work a widget test's clock
/// never performs, so the screen would sit there as a member whatever the
/// roster said. What is under test is which half of the screen each answer
/// draws, so the answer is handed over directly.
class _Roster extends ChannelRosterController {
  _Roster({required this.iAmAdmin, this.iAmOwner = false});

  final bool iAmAdmin;
  final bool iAmOwner;

  @override
  Map<String, Map<String, ChannelMember>> build() {
    // Deliberately not calling super.build(): it loads the roster off Hive and
    // would replace this one a frame later.
    return {
      '#room': {
        _me: ChannelMember(
          id: _me,
          name: 'Me',
          isAdmin: iAmAdmin,
          isOwner: iAmOwner,
          lastSeen: DateTime(2026, 9, 16),
        ),
        _olena: ChannelMember(
          id: _olena,
          name: 'Olena',
          isAdmin: !iAmAdmin,
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
      state[channel]![_me]!;
}

/// The channel screen the owner asked for with screenshots: the picture across
/// the top, a row of round actions under it, and the rest as rows you open.
/// The member's version is the same screen without the administrator's half.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_channel_ui_');
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
    bool asAdmin = true,
    bool asOwner = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(
      overrides: [
        channelRosterControllerProvider.overrideWith(
          () => _Roster(iAmAdmin: asAdmin, iAmOwner: asOwner),
        ),
      ],
    );
    await container.read(channelControllerProvider.notifier).join('#room');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChannelInfoScreen(channelName: '#room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return container;
  }

  /// The providers behind this screen keep timers of their own (conversation
  /// settings sweeps mutes once a minute), so the container goes down inside
  /// the test, where the pending-timer check runs.
  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('the room wears its name over the cover, with rows to open',
      (tester) async {
    final container = await pump(tester);

    expect(find.text('#room'), findsOneWidget);
    expect(find.textContaining('private channel'), findsOneWidget);
    // The round actions.
    expect(find.byIcon(Icons.perm_media_rounded), findsWidgets);
    expect(find.byIcon(Icons.notifications_active_rounded), findsOneWidget);
    // And the rows.
    expect(find.text('Participants'), findsOneWidget);
    expect(find.text('Administrators'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester, container);
  });

  testWidgets('an administrator gets the pencil and the settings row',
      (tester) async {
    final container = await pump(tester);
    expect(find.byIcon(Icons.edit_rounded), findsOneWidget);
    expect(find.text('Channel settings'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.edit_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Set a new photo'), findsOneWidget);
    expect(find.text('Description'), findsOneWidget);
    await finish(tester, container);
  });

  testWidgets('a member sees no administrator controls at all', (tester) async {
    // The last screenshot: what somebody who does not run the room gets. Not
    // the same screen greyed out — the administrator's half is absent, and the
    // way out of the room takes its place.
    final container = await pump(tester, asAdmin: false);

    expect(find.byIcon(Icons.edit_rounded), findsNothing);
    expect(find.text('Channel settings'), findsNothing);
    expect(find.byIcon(Icons.person_add_alt_1_rounded), findsNothing);
    // What a member has instead: share the room, and leave it.
    expect(find.byIcon(Icons.ios_share_rounded), findsOneWidget);
    expect(find.byIcon(Icons.logout_rounded), findsOneWidget);
    // And the rows everyone can open are still there.
    expect(find.text('Participants'), findsOneWidget);
    await finish(tester, container);
  });

  testWidgets('only the room owner is offered the end of it', (tester) async {
    final member = await pump(tester, asAdmin: false);
    expect(find.byIcon(Icons.delete_forever_rounded), findsNothing);
    await finish(tester, member);

    final owner = await pump(tester, asOwner: true);
    expect(find.byIcon(Icons.delete_forever_rounded), findsOneWidget);
    await finish(tester, owner);
  });

  testWidgets('the participants row opens the people', (tester) async {
    final container = await pump(tester);
    await tester.tap(find.text('Participants'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Olena'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester, container);
  });
}
