import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/widgets/floating_glass.dart';
import '../../../../l10n/app_localizations.dart';
import '../../data/voice_playback_controller.dart';
import 'voice_island.dart';

/// The bar that follows a playing voice message around the app.
///
/// Playback outliving the chat is only useful if you can still reach it, so
/// this rides in the app-level builder rather than in a screen or the tab
/// shell: pushed routes — a contact profile, the search screen, another chat —
/// are still routes, and walking into one is the ordinary way of leaving a
/// conversation while listening to it.
///
/// Deliberately at the top, under the status bar, not at the bottom. The bottom
/// is where the composer and the nav bar live, and a bar that appears there
/// moves the controls out from under a thumb that is already reaching for them.
/// It is also where the eye goes for "what is this screen", which is the
/// question this bar answers about itself.
class VoiceMiniPlayer extends ConsumerWidget {
  const VoiceMiniPlayer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(voicePlaybackControllerProvider);
    // A chat showing its own island is already saying all of this, in the same
    // place. Two of them would stack, and the lower one would sit over the
    // conversation for no reason.
    final ownedByChat = ref.watch(voiceIslandOwnerProvider) != null;

    return Stack(
      children: [
        Positioned.fill(child: child),
        // Nothing playing, nothing painted — and no hit-testing either, or an
        // invisible bar would eat taps meant for the header beneath it.
        if (playback.isActive && !ownedByChat)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 6,
            left: 10,
            right: 10,
            child: _Bar(playback: playback),
          ),
      ],
    );
  }
}

class _Bar extends ConsumerWidget {
  const _Bar({required this.playback});

  final VoicePlayback playback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final controller = ref.read(voicePlaybackControllerProvider.notifier);

    return FloatingGlass(
      borderRadius: 22,
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          // Tapping the bar goes back to where the voice came from, which is
          // the only navigation anyone wants from here.
          onTap: playback.chatId == null
              ? null
              : () => context.push(
                    '/chat/${Uri.encodeComponent(playback.chatId!)}'
                    '?name=${Uri.encodeQueryComponent(playback.chatTitle ?? '')}',
                  ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 6, 6),
                child: Row(
                  children: [
                    _RoundButton(
                      icon: playback.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      tooltip: playback.playing ? t.chatPause : t.chatPlay,
                      onPressed: controller.togglePlayPause,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            t.voicePlayingFrom(playback.chatTitle ?? ''),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textOnGlass,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${_fmt(playback.position)} / '
                            '${_fmt(playback.duration)}',
                            style: TextStyle(
                              color: AppColors.textOnGlassDim,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Speed earns its place on a bar for *speech*: skimming a
                    // long voice note is the main reason to look at this thing
                    // rather than just listen to it.
                    _SpeedPill(
                      speed: playback.speed,
                      onTap: controller.cycleSpeed,
                    ),
                    const SizedBox(width: 2),
                    _RoundButton(
                      icon: Icons.close_rounded,
                      tooltip: t.cancel,
                      onPressed: controller.stop,
                    ),
                  ],
                ),
              ),
              // A hairline of progress along the bottom edge. Enough to see how
              // far in you are without spending a row on a scrubber that
              // duplicates the bubble's.
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(22),
                ),
                child: LinearProgressIndicator(
                  value: playback.progress,
                  minHeight: 2.5,
                  backgroundColor: AppColors.glass(0.10),
                  valueColor: AlwaysStoppedAnimation(
                    AppColors.brandPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkResponse(
          onTap: onPressed,
          radius: 22,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.brandPrimary.withValues(alpha: 0.18),
            ),
            child: Icon(icon, size: 20, color: AppColors.textOnGlass),
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
    final label = speed == speed.roundToDouble()
        ? '${speed.toInt()}x'
        : '${speed.toStringAsFixed(1)}x';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            color: speed == 1.0
                ? AppColors.textOnGlassDim
                : AppColors.brandPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
