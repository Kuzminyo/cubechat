import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import '../../data/voice_playback_controller.dart';

/// Shares the active decoder with the bubble; never opens another video.
class CirclePlaybackThumbnail extends ConsumerWidget {
  const CirclePlaybackThumbnail({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(voicePlaybackControllerProvider);
    final video = ref.read(voicePlaybackControllerProvider.notifier).video;
    if (!playback.isCircle || video == null || !video.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ClipOval(
        child: SizedBox.square(
          dimension: 34,
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: video.value.size.width,
              height: video.value.size.height,
              child: VideoPlayer(video),
            ),
          ),
        ),
      ),
    );
  }
}
