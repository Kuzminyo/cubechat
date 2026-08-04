import 'dart:io';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/channels/data/channel_roster_controller.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// Saved notes borrow the channel screen, because a notebook and a room are the
/// same shape: many messages, no handshake, nobody online. What they do not
/// share is the header — a poll needs voters, an invitation needs someone to
/// invite, and tapping the name used to open channel info for a room called
/// `saved`, which not only showed a room that does not exist but created one on
/// the way in.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_saved_screen_');
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

  Future<void> beat(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<ProviderContainer> openSaved(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await beat(tester);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));

    await tester.tap(find.byIcon(Icons.more_vert));
    await beat(tester);
    await tester.tap(find.text('Saved').last);
    await beat(tester);
    return container;
  }

  testWidgets('a notebook offers no poll and nobody to invite', (tester) async {
    await openSaved(tester);

    expect(find.byTooltip('Search'), findsOneWidget,
        reason: 'searching your own notes is the one header action that '
            'still means something');
    expect(find.byIcon(Icons.poll_outlined), findsNothing);
    expect(find.byIcon(Icons.person_add_alt_1_outlined), findsNothing);
  });

  testWidgets('the header carries a bookmark, not an initial', (tester) async {
    await openSaved(tester);

    expect(find.byIcon(Icons.bookmark_rounded), findsWidgets);
    expect(
      find.text('S'),
      findsNothing,
      reason: 'an initial taken off the title says only which language the app '
          'is in — the same notebook was a "З" in Ukrainian',
    );
  });

  testWidgets('tapping the name opens what is in the notebook, not a room',
      (tester) async {
    final container = await openSaved(tester);

    await tester.tap(find.text('Saved').first);
    await beat(tester);

    // Everything a notebook has, sorted — the same shared-content screen a
    // contact has.
    expect(find.text('Media'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Links'), findsOneWidget);

    expect(find.text('Channel info'), findsNothing);
    // ensureSelf() writes a roster entry for whatever name it is handed, so the
    // navigation this replaced left a persisted member list for a room nobody
    // ever created.
    expect(
      container.read(channelRosterControllerProvider).keys,
      isNot(contains('saved')),
    );
  });
}
