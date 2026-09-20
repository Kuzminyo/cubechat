import 'dart:io';
import 'package:video_player/video_player.dart';
import 'package:cubechat/features/chat/data/voice_playback_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/widgets/video_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Playback extends VoicePlaybackController {
  final _fakeVideo = VideoPlayerController.file(File('unused'));
  @override
  VideoPlayerController get video => _fakeVideo;
  @override
  VoicePlayback build() {
    _fakeVideo.value = _fakeVideo.value
        .copyWith(isInitialized: true, size: const Size(720, 1280));
    return const VoicePlayback(
        messageId: 'circle',
        isCircle: true,
        playing: true,
        duration: Duration(seconds: 10));
  }

  void tick(int milliseconds) =>
      state = state.copyWith(position: Duration(milliseconds: milliseconds));
}

void main() {
  testWidgets('position ticks preserve the circle surface subtree',
      (tester) async {
    final container = ProviderContainer(overrides: [
      voicePlaybackControllerProvider.overrideWith(_Playback.new)
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            home: Scaffold(
                body: VideoBubble(
                    message: Message(
                        id: 'circle',
                        chatId: 'peer',
                        text: 'video/mp4',
                        sentAt: DateTime(2026),
                        isMine: true,
                        kind: MessageKind.file,
                        fileName: Message.circleFileName))))));
    await tester.pump(const Duration(milliseconds: 300));

    final playback =
        container.read(voicePlaybackControllerProvider.notifier) as _Playback;
    playback.tick(1000);
    await tester.pump();
    final surface = tester.widget<ClipOval>(find.byType(ClipOval));
    final video = tester.widget<VideoPlayer>(find.byType(VideoPlayer));
    for (var i = 1; i <= 15; i++) {
      playback.tick(1000 + i * 66);
      await tester.pump(const Duration(milliseconds: 66));
      expect(identical(tester.widget<ClipOval>(find.byType(ClipOval)), surface),
          isTrue,
          reason:
              'progress must not recreate the camera texture and clipping subtree');
    }
    expect(tester.widget<VideoPlayer>(find.byType(VideoPlayer)), same(video));
    expect(find.text('0:08'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
