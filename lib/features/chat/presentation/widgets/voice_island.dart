import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/colors.dart';
import '../../../../l10n/app_localizations.dart';
import '../../data/voice_playback_controller.dart';

/// The chat that is currently drawing its own voice island.
///
/// The app-wide bar and the in-chat island are the same information, so exactly
/// one of them should be on screen. The chat claims this while it is mounted
/// and the global bar stands down; leave the chat and the bar takes over
/// mid-sentence, which is the behaviour that made playback outlive the screen
/// worth having.
final voiceIslandOwnerProvider = StateProvider<String?>((_) => null);

/// Two panels in one capsule: the chat header, and the voice note playing.
///
/// A playing voice note has to be reachable from the chat it is in, but the
/// header is what tells you whose chat you are looking at — and there is only
/// one capsule's worth of room at the top. Rather than stack them and push the
/// conversation down the screen, they take turns: a downward swipe on the
/// capsule shows the other one.
///
/// Same height, radius and insets as the header alone, because it *is* the
/// header slot — a control that changed size when audio started would move the
/// back button out from under a thumb already reaching for it.
class VoiceIsland extends ConsumerStatefulWidget {
  const VoiceIsland({
    super.key,
    required this.chatId,
    required this.header,
    required this.height,
  });

  final String chatId;
  final Widget header;
  final double height;

  @override
  ConsumerState<VoiceIsland> createState() => _VoiceIslandState();
}

class _VoiceIslandState extends ConsumerState<VoiceIsland> {
  /// Which panel is face up. Starts on the voice note, because it only appears
  /// at all when one has just started.
  bool _showVoice = true;

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

    // Nothing playing: the header is the whole story, and the swipe has nothing
    // to swap to.
    if (!playback.isActive) {
      _showVoice = true; // ready for the next one
      return widget.header;
    }

    return GestureDetector(
      // Vertical only, so it never fights the conversation's own scroll.
      onVerticalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v.abs() < 80) return;
        // Down reveals the header, up puts the voice note back — the direction
        // the panel itself appears to travel.
        setState(() => _showVoice = v < 0);
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.center,
          children: [...previous, if (current != null) current],
        ),
        transitionBuilder: (child, animation) {
          // Slides in from above and out downwards, so the two panels read as
          // one object rolling over rather than two fading into each other.
          final incoming = child.key == ValueKey(_showVoice);
          return ClipRect(
            child: SlideTransition(
              position: Tween<Offset>(
                begin: Offset(0, incoming ? -1 : 1),
                end: Offset.zero,
              ).animate(animation),
              child: FadeTransition(opacity: animation, child: child),
            ),
          );
        },
        child: _showVoice
            ? KeyedSubtree(
                key: const ValueKey(true),
                child: _VoicePanel(
                  playback: playback,
                  height: widget.height,
                ),
              )
            : KeyedSubtree(key: const ValueKey(false), child: widget.header),
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
                Text(
                  t.voicePlayingFrom(playback.chatTitle ?? ''),
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
