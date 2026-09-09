import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/app.dart';
import 'package:cubechat/core/widgets/circle_video_icon.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// One button records two things, and a tap turns it over.
///
/// The tap and the hold share a recogniser set, so they settle it between
/// themselves in the arena — the thing worth pinning is that a quick touch
/// really does reach the toggle rather than being eaten by the long press that
/// starts a recording.
void main() {
  late Directory tempDir;
  final peerHex = 'ab' * 32;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_recmode_');
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

  Future<void> openChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await beat(tester);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));
    container.read(knownPeersControllerProvider.notifier).upsert(
          pubkeyHex: peerHex,
          displayName: 'Alice',
          signPublicKey: Uint8List(32),
        );
    container.read(messagesControllerProvider.notifier).append(
          peerHex,
          Message(
            id: 'm1',
            chatId: peerHex,
            text: 'привіт',
            sentAt: DateTime(2026, 9, 9, 10),
            isMine: false,
            wireId: 'cd' * 16,
          ),
        );
    await beat(tester);
    await tester.tap(find.text('Alice').first);
    await beat(tester);
  }

  testWidgets('tapping the microphone turns it into a camera', (tester) async {
    await openChat(tester);

    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    expect(find.byType(CircleVideoIcon), findsNothing);

    await tester.tap(find.byIcon(Icons.mic_rounded));
    // Past the halfway point of the flip, where the face is edge-on and the
    // glyph is swapped.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(find.byType(CircleVideoIcon), findsOneWidget);
    expect(find.byIcon(Icons.mic_rounded), findsNothing);
  });

  testWidgets('and back again', (tester) async {
    await openChat(tester);

    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byType(CircleVideoIcon));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
  });
}
