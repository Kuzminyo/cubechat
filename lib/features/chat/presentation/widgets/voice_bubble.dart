import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/identity/anon_name.dart';
import '../../../../core/identity/nickname_controller.dart';
import '../../../../core/theme/colors.dart';
import '../../../../core/utils/time_format.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../core/util/media_storage.dart';
import '../../../peers/data/contact_aliases_controller.dart';
import '../../../peers/data/known_peers_controller.dart';
import '../../data/voice_playback_controller.dart';
import '../../models/message.dart';

/// Renders a voice message: play/pause button + progress bar + duration.
///
/// Owns no player. It used to own one each, disposed with the widget — which
/// meant scrolling the bubble off screen, or leaving the chat, cut the audio
/// mid-sentence. Playback lives in [voicePlaybackControllerProvider] now and
/// outlives every screen; this widget only shows the state of the one message
/// it represents, and hands taps on.
class VoiceBubble extends ConsumerStatefulWidget {
  const VoiceBubble({
    super.key,
    required this.message,
    this.chatId,
    this.chatTitle,
    this.showHeader = false,
  });

  final Message message;

  /// The bucket this bubble is rendered in — a peer's pubkey hex or a
  /// `#channel`.
  ///
  /// Needed because [Message.chatId] is not reliably that: a note that arrived
  /// over Bluetooth carries the *transport* id of the device it came in on, so
  /// looking a contact up by it missed and the player fell all the way through
  /// to "unknown device" for somebody whose name is in the header two
  /// centimetres above.
  final String? chatId;

  /// Whose voice this is, for the mini player's caption. A last resort — the
  /// bubble works the name out itself (see [_authorName]) and only falls back
  /// to this when nothing else identifies the sender.
  final String? chatTitle;

  /// Draw a line naming the sender and when it was sent, above the player.
  ///
  /// Off inside a conversation, where both are already answered by which side
  /// of the screen the bubble is on and by the clock beneath it. On in the
  /// media list, where the rows are stripped of every one of those cues: a
  /// column of identical play buttons and durations, with nothing to say who
  /// any of them is from or whether it arrived this morning or in March.
  final bool showHeader;

  @override
  ConsumerState<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends ConsumerState<VoiceBubble> {
  /// Fraction (0..1) of the bar the user is currently dragging the thumb
  /// to. Non-null = drag in progress; the actual seek commits on release.
  /// While dragging we render the thumb at this position so the UI feels
  /// responsive even when the underlying decoder hasn't seeked yet.
  double? _scrubbing;

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Who this voice note is from, as a name a person would recognise.
  ///
  /// The playing bar showed the *chat id* before — a 64-character pubkey hex,
  /// or a `#channel` — because nothing ever passed `chatTitle` and the fallback
  /// was the raw bucket key. The sender is knowable from the message itself in
  /// every case, so work it out here rather than making three call sites
  /// remember to hand it in:
  ///
  ///  * mine — my own nickname;
  ///  * a channel — the author name the signature resolved to;
  ///  * a 1:1 — the contact filed under this chat's pubkey.
  String _authorName(BuildContext context) {
    final message = widget.message;
    if (message.isMine) {
      final mine = ref.read(nicknameControllerProvider).trim();
      if (mine.isNotEmpty) return mine;
      return AppLocalizations.of(context).chatReplyYou;
    }
    final author = message.authorName?.trim();
    if (author != null && author.isNotEmpty) return author;
    final peers = ref.read(knownPeersControllerProvider);
    // The rendered bucket first, the message's own id second: the former is
    // the canonical pubkey wherever the caller knows it, the latter is only
    // right for a message that came in over the relay.
    final peer = peers[widget.chatId ?? ''] ?? peers[message.chatId];
    if (peer != null) {
      return contactDisplayName(
        alias: ref.read(contactAliasesControllerProvider)[peer.pubkeyHex],
        rawBroadcastName: peer.displayName,
        pubkeyHex: peer.pubkeyHex,
      );
    }
    final given = widget.chatTitle?.trim();
    if (given != null && given.isNotEmpty) return given;
    return AppLocalizations.of(context).bleUnknownPeer;
  }

  @override
  Widget build(BuildContext context) {
    final playback = ref.watch(voicePlaybackControllerProvider);
    final isCurrent = playback.isCurrent(widget.message.id);
    final hasFile = MediaPaths.existsOrNull(widget.message.audioPath);

    final declared =
        Duration(milliseconds: widget.message.audioDurationMs ?? 0);
    // The decoder's own duration is better than the declared one, but only
    // exists for the message actually loaded.
    final total = isCurrent && playback.duration > Duration.zero
        ? playback.duration
        : declared;
    final position = isCurrent ? playback.position : Duration.zero;
    final playing = isCurrent && playback.playing;
    final progress = total > Duration.zero
        ? (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    Future<void> toggle() => ref
        .read(voicePlaybackControllerProvider.notifier)
        .toggle(
          messageId: widget.message.id,
          path: widget.message.audioPath!,
          // The rendered bucket, so tapping the bar returns to the right chat
          // even for a note that arrived over a Bluetooth transport id.
          chatId: widget.chatId ?? widget.message.chatId,
          chatTitle: _authorName(context),
          sentAt: widget.message.sentAt,
          knownDuration: declared > Duration.zero ? declared : null,
        );

    final player = SizedBox(
      width: 200,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: hasFile ? toggle : null,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hasFile
                    ? AppColors.brandPrimary.withValues(alpha: 0.25)
                    : AppColors.glass(0.08),
              ),
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: hasFile
                    ? AppColors.textOnGlass
                    : AppColors.textOnGlassFaint,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _ScrubBar(
                  progress: _scrubbing ?? progress,
                  enabled: hasFile && total > Duration.zero,
                  onSeekStart: (frac) => setState(() => _scrubbing = frac),
                  onSeekUpdate: (frac) => setState(() => _scrubbing = frac),
                  onSeekCommit: (frac) async {
                    setState(() => _scrubbing = null);
                    // Seeking a message that is not the current one has nothing
                    // to seek: start it there instead.
                    if (!isCurrent) await toggle();
                    await ref
                        .read(voicePlaybackControllerProvider.notifier)
                        .seekFraction(frac);
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  _fmt(playing
                      ? position
                      : (_scrubbing == null
                          ? total
                          : Duration(
                              milliseconds:
                                  (total.inMilliseconds * _scrubbing!).round(),
                            ))),
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (!widget.showHeader) return player;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              widget.message.isMine
                  ? Icons.north_east_rounded
                  : Icons.south_west_rounded,
              size: 13,
              color: AppColors.textOnGlassFaint,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                _authorName(context),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              // Bare time for today, date and time for anything older — the
              // same rule the message details use, and the right one here for
              // the same reason: this list is read to answer "when was that".
              formatMessageDetailsTime(context, widget.message.sentAt),
              style: TextStyle(
                color: AppColors.textOnGlassFaint,
                fontSize: 11.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        player,
      ],
    );
  }
}

/// Tappable + draggable playback scrubber. Renders a thin progress bar
/// with a small thumb at the current position; horizontal-drag/tap on the
/// bar reports the new fractional position via the seek callbacks. The
/// parent owns the actual seek + UI state.
class _ScrubBar extends StatelessWidget {
  const _ScrubBar({
    required this.progress,
    required this.enabled,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekCommit,
  });

  final double progress;
  final bool enabled;
  final ValueChanged<double> onSeekStart;
  final ValueChanged<double> onSeekUpdate;
  final ValueChanged<double> onSeekCommit;

  double _fracFor(double localX, double width) {
    if (width <= 0) return 0;
    return (localX / width).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: enabled
              ? (d) => onSeekStart(_fracFor(d.localPosition.dx, width))
              : null,
          onHorizontalDragUpdate: enabled
              ? (d) => onSeekUpdate(_fracFor(d.localPosition.dx, width))
              : null,
          onHorizontalDragEnd:
              enabled ? (_) => onSeekCommit(progress.clamp(0.0, 1.0)) : null,
          onTapDown: enabled
              ? (d) => onSeekStart(_fracFor(d.localPosition.dx, width))
              : null,
          onTapUp: enabled
              ? (d) => onSeekCommit(_fracFor(d.localPosition.dx, width))
              : null,
          // Hit area is taller than the visual bar so it's easy to grab.
          child: SizedBox(
            height: 16,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.glass(0.12),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: progress.clamp(0.0, 1.0),
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.brandPrimary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Positioned(
                  left: (width * progress.clamp(0.0, 1.0)) - 6,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: enabled
                          ? AppColors.brandPrimary
                          : AppColors.textOnGlassFaint,
                      border: Border.all(color: AppColors.ink(0.4)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
