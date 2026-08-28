import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/data/conversation_settings_controller.dart';
import '../../chat/presentation/widgets/chat_input.dart';
import '../data/channel_controller.dart';
import '../data/channel_roster_controller.dart';

/// What sits where the composer would, for somebody who cannot post here.
///
/// An announcement channel has readers, and the app was handing every one of
/// them a text field, an attach button and a microphone that did nothing —
/// `canSend` was consulted at the moment of sending, so the island invited a
/// message and then swallowed it. A reader's three questions are "what is in
/// here", "must it interrupt me", and "what is everyone saying about it", so
/// those are the three controls, in the place the island already occupies.
///
/// Deliberately the same glass as the composer. It is not a banner explaining
/// an absence; it is what this room's island *is* when you are reading rather
/// than writing.
class ChannelViewerBar extends ConsumerWidget {
  const ChannelViewerBar({
    super.key,
    required this.channelName,
    required this.onSearch,
    required this.onOpenCommunity,
  });

  final String channelName;

  final VoidCallback onSearch;

  /// Takes the reader to the discussion room. Given rather than done here so
  /// the navigation stays with the screen that owns the route.
  final VoidCallback onOpenCommunity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final muted = ref.watch(
      conversationSettingsControllerProvider.select(
        (all) => all[channelName]?.isMutedNow ?? false,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Row(
        children: [
          _RoundGlassButton(
            icon: Icons.search_rounded,
            tooltip: t.chatSearchTitle,
            onTap: onSearch,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: MessageIslandGlass(
              borderRadius: 26,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(26),
                  onTap: () => _toggleMute(context, ref, muted: muted),
                  // Held down, it offers a length rather than forever: the
                  // common case is one loud evening, and a mute you have to
                  // remember to undo is one you will not.
                  onLongPress: () => _pickDuration(context, ref),
                  child: SizedBox(
                    height: 52,
                    child: Center(
                      child: Text(
                        muted ? t.channelUnmute : t.channelMute,
                        style: TextStyle(
                          color: AppColors.textOnGlass,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _RoundGlassButton(
            icon: Icons.mode_comment_outlined,
            tooltip: t.channelCommunity,
            onTap: onOpenCommunity,
          ),
        ],
      ),
    );
  }

  Future<void> _toggleMute(
    BuildContext context,
    WidgetRef ref, {
    required bool muted,
  }) async {
    HapticFeedback.selectionClick();
    await ref
        .read(conversationSettingsControllerProvider.notifier)
        .setMuted(channelName, !muted);
  }

  Future<void> _pickDuration(BuildContext context, WidgetRef ref) async {
    HapticFeedback.selectionClick();
    final t = AppLocalizations.of(context);
    final choices = <(String, Duration?)>[
      (t.channelMuteHours(1), const Duration(hours: 1)),
      (t.channelMuteHours(8), const Duration(hours: 8)),
      (t.channelMuteDays(2), const Duration(days: 2)),
      (t.channelMuteForever, null),
    ];
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.bgTop,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  t.channelMuteFor,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            for (var i = 0; i < choices.length; i++)
              ListTile(
                title: Text(
                  choices[i].$1,
                  style: TextStyle(color: AppColors.textOnGlass),
                ),
                onTap: () => Navigator.of(sheetContext).pop(i),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    final span = choices[picked].$2;
    await ref.read(conversationSettingsControllerProvider.notifier).setMuted(
          channelName,
          true,
          until: span == null ? null : DateTime.now().add(span),
        );
  }
}

/// The two round buttons either side of the pill.
class _RoundGlassButton extends StatelessWidget {
  const _RoundGlassButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: MessageIslandGlass(
        borderRadius: 26,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(26),
            onTap: onTap,
            child: SizedBox(
              width: 52,
              height: 52,
              child: Icon(icon, size: 22, color: AppColors.textOnGlass),
            ),
          ),
        ),
      ),
    );
  }
}

/// Open a channel's discussion room, joining it on the way if this is the
/// first time.
///
/// Nothing is sent and nobody is asked: the room's key falls out of the
/// channel's own key, so opening comments is a derivation rather than a
/// request. See [ChannelCrypto.deriveCommunityKey].
///
/// Returns the room's name, or null when we are not in the channel and so have
/// nothing to derive from.
Future<String?> openCommunityFor(WidgetRef ref, String channelName) async {
  final channels = ref.read(channelControllerProvider.notifier);
  final roster = ref.read(channelRosterControllerProvider.notifier);
  final self = await roster.selfMemberId();
  final community = await channels.joinCommunity(
    channelName,
    // Whoever runs the channel runs its comments. Everyone else arrives the
    // way an invitee does, which is what keeps the seat from going to whoever
    // tapped this first.
    asAdmin: roster.isAdmin(channelName, self),
  );
  if (community == null) return null;
  // `adminWhenFirst` is a request, not a grant: [ensureSelf] refuses it for a
  // room joined via an invitation, and [joinCommunity] marked this one that way
  // for everybody who does not run the channel.
  await roster.ensureSelf(community.name, adminWhenFirst: true);
  return community.name;
}

/// Say why nothing opened, rather than leaving a tap unanswered.
void showCommunityUnavailable(BuildContext context) {
  showGlassToast(
    context,
    AppLocalizations.of(context).channelCommunityOpen,
    icon: Icons.mode_comment_outlined,
    tone: ToastTone.danger,
  );
}
