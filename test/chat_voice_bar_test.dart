import 'dart:io';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/channels/data/channel_controller.dart';
import 'package:cubechat/features/chat/data/voice_playback_controller.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// A voice note playing must not cost the back button.
///
/// The bar used to *be* the header: the two took turns in one capsule, swapped
/// by a downward swipe, so while anything was playing there was no back button
/// on screen and nothing saying it was one gesture away. It has its own island
/// under the header now.
class _FakePlayback extends VoicePlaybackController {
  @override
  VoicePlayback build() => VoicePlayback.idle;

  /// Starts "playing" without an audio player — the bar only reads the state.
  void pretendPlaying() => state = const VoicePlayback(
        messageId: 'm1',
        chatId: '#kvartira',
        chatTitle: 'kvartira',
        duration: Duration(seconds: 8),
        playing: true,
      );
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_voicebar_');
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

  testWidgets('the header keeps its back button while a voice note plays',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voicePlaybackControllerProvider.overrideWith(_FakePlayback.new),
        ],
        child: const CubechatApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await beat(tester);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));
    await container.read(channelControllerProvider.notifier).join('kvartira');
    await beat(tester);
    await tester.tap(find.text('#kvartira').first);
    await beat(tester);

    // Playback starts once the chat is open, which is the case that used to
    // swallow the header.
    (container.read(voicePlaybackControllerProvider.notifier) as _FakePlayback)
        .pretendPlaying();
    await beat(tester);

    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.text('#kvartira'), findsWidgets, reason: 'and the name with it');

    // The bar is there too, below the header rather than instead of it.
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    final headerBottom = tester.getRect(find.byTooltip('Back')).bottom;
    final barTop = tester.getRect(find.byIcon(Icons.pause_rounded)).top;
    expect(
      barTop,
      greaterThanOrEqualTo(headerBottom - 1),
      reason: 'the voice island belongs under the header, not over it',
    );
  });
}
