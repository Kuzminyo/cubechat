import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/colors.dart';
import '../../../../l10n/app_localizations.dart';
import 'chat_input.dart' show MessageIslandGlass;
import '../../data/voice_playback_controller.dart';

/// The chat that is currently drawing its own voice island.
///
/// The app-wide bar and the in-chat island are the same information, so exactly
/// one of them should be on screen. The chat claims this while it is mounted
/// and the global bar stands down; leave the chat and the bar takes over
/// mid-sentence, which is the behaviour that made playback outlive the screen
/// worth having.
final voiceIslandOwnerProvider = StateProvider<String?>((_) => null);

/// The voice note that is playing, as its own island in a chat.
///
/// It used to *be* the header: the two panels took turns in one capsule,
/// swapped by a downward swipe. That saved a strip of screen and cost the back
/// button — while anything was playing there was none on screen, and nothing
/// saying it was one swipe away. So the bar sits under the header now, under
/// the pinned island too when there is one, in the order things are read.
///
/// Renders nothing when nothing is playing, and claims
/// [voiceIslandOwnerProvider] while it is mounted so the app-wide bar — the
/// same information, in the same place — stands down.
class ChatVoiceBar extends ConsumerStatefulWidget {
  const ChatVoiceBar({super.key, required this.chatId});

  final String chatId;

  @override
  ConsumerState<ChatVoiceBar> createState() => _ChatVoiceBarState();
}

class _ChatVoiceBarState extends ConsumerState<ChatVoiceBar> {
  static const double _height = 56;

  @override
  void initState() {
    super.initState();
    // After the frame: this runs during a build of the chat, and the global bar
    // watches the same provider.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(voiceIslandOwnerProvider.notifier).state = widget.chatId;
      }
    });
  }

  /// Captured while an ancestor lookup is still legal. dispose() cannot call
  /// ProviderScope.containerOf — the element is already being unmounted — and
  /// doing so threw while finalizing the tree.
  ProviderContainer? _container;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  @override
  void dispose() {
    final container = _container;
    final claimed = widget.chatId;
    if (container != null) {
      // A frame later, not now. Writing to a provider inside dispose modifies
      // state while the tree is being finalized, which Riverpod refuses
      // outright — and the ancestor lookup it would need is illegal here too,
      // which is why the container was captured earlier.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          final owner = container.read(voiceIslandOwnerProvider.notifier);
          // Only release what we claimed: a chat pushed on top of this one has
          // already taken over by the time we unwind.
          if (owner.state == claimed) owner.state = null;
        } on Object {
          // The whole container can go with the app; nothing left to release.
        }
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playback = ref.watch(voicePlaybackControllerProvider);
    // Grown and shrunk rather than swapped in and out. The conversation's top
    // padding follows this column's height, so an island that simply appeared
    // shoved the whole conversation down a notch in one frame — and closing one
    // yanked it back up. Both ends are 220 ms of easing now, and the list rides
    // the same curve because it is measuring the same box.
    return ClipRect(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedOpacity(
          opacity: playback.isActive ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: playback.isActive
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: SizedBox(
                    height: _height,
                    child: MessageIslandGlass(
                      borderRadius: _height / 2,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: _VoicePanel(playback: playback, height: _height),
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ),
    );
  }
}

/// The voice half of the capsule: play/pause, who it is from, elapsed time,
/// speed, and a grabber saying the thing can be swapped.
class _VoicePanel extends ConsumerWidget {
  const _VoicePanel({required this.playback, required this.height});

  final VoicePlayback playback;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final controller = ref.read(voicePlaybackControllerProvider.notifier);

    return SizedBox(
      height: height,
      child: Row(
        children: [
          const SizedBox(width: 4),
          _CircleButton(
            icon: playback.playing
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
            tooltip: playback.playing ? t.chatPause : t.chatPlay,
            onTap: controller.togglePlayPause,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The name on its own. "Voice message from Roma" spent most of
                // a narrow capsule restating what the play button, the
                // waveform and the timer already say, and then ellipsised the
                // one word that was actually news.
                Text(
                  playback.chatTitle ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                // The progress line sits under the caption rather than at the
                // capsule's edge: the capsule is fully rounded, and a bar
                // tucked into that curve reads as a rendering artefact.
                Row(
                  children: [
                    Text(
                      '${_fmt(playback.position)} / ${_fmt(playback.duration)}',
                      style: TextStyle(
                        color: AppColors.textOnGlassDim,
                        fontSize: 10.5,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: playback.progress,
                          minHeight: 2.5,
                          backgroundColor: AppColors.glass(0.12),
                          valueColor: AlwaysStoppedAnimation(
                            AppColors.brandPrimary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _SpeedPill(speed: playback.speed, onTap: controller.cycleSpeed),
          _CircleButton(
            icon: Icons.close_rounded,
            tooltip: t.cancel,
            onTap: controller.stop,
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkResponse(
          onTap: onTap,
          radius: 24,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.brandPrimary.withValues(alpha: 0.18),
            ),
            child: Icon(icon, size: 21, color: AppColors.textOnGlass),
          ),
        ),
      );
}

class _SpeedPill extends StatelessWidget {
  const _SpeedPill({required this.speed, required this.onTap});

  final double speed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label =
        speed == speed.roundToDouble() ? '${speed.toInt()}x' : '${speed}x';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            color:
                speed == 1.0 ? AppColors.textOnGlassDim : AppColors.brandPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
