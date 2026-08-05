import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/widgets/floating_glass.dart';
import '../../../../l10n/app_localizations.dart';

/// What the attach island resolved to.
enum AttachChoice { gallery, camera, file, poll }

/// The row of attachment categories, floating over the picker as its own
/// island rather than sitting in a plate along the bottom edge.
///
/// Only three entries, and all three do something. The obvious reference here
/// has five — wallet, location, contacts — but a button that opens nothing is
/// worse than an absent one: it reads as a half-finished app rather than a
/// focused one. Categories get added when the feature behind them exists.
class AttachIsland extends StatelessWidget {
  const AttachIsland({
    super.key,
    required this.selected,
    required this.onPick,
    this.bare = false,
    this.allowFiles = true,
    this.allowPoll = false,
  });

  final AttachChoice selected;
  final ValueChanged<AttachChoice> onPick;

  /// True when the row already sits on a pane of glass — inside the picker
  /// sheet, which is one island itself. A second glass surface inside the
  /// first is the "card on a plate" look this app does not have anywhere else.
  final bool bare;

  /// False in a channel, where photos travel but arbitrary files do not — every
  /// member relays every chunk, so an attachment costs the whole room. Same
  /// principle as the rest of this row: a category that opens nothing is worse
  /// than an absent one.
  final bool allowFiles;

  /// True in a channel. A poll needs voters, so it means nothing in a 1:1 — but
  /// in a room it is one of the things you attach, and it belongs beside the
  /// gallery and the camera rather than as a third icon in the header.
  final bool allowPoll;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final row = Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _AttachTab(
          icon: Icons.photo_library_outlined,
          label: t.attachGallery,
          active: selected == AttachChoice.gallery,
          onTap: () => onPick(AttachChoice.gallery),
        ),
        _AttachTab(
          icon: Icons.photo_camera_outlined,
          label: t.attachCamera,
          active: selected == AttachChoice.camera,
          onTap: () => onPick(AttachChoice.camera),
        ),
        if (allowFiles)
          _AttachTab(
            icon: Icons.insert_drive_file_outlined,
            label: t.attachFile,
            active: selected == AttachChoice.file,
            onTap: () => onPick(AttachChoice.file),
          ),
        if (allowPoll)
          _AttachTab(
            icon: Icons.how_to_vote_outlined,
            label: t.channelPollTitle,
            active: selected == AttachChoice.poll,
            onTap: () => onPick(AttachChoice.poll),
          ),
      ],
    );
    if (bare) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
        child: row,
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: FloatingGlass(
        borderRadius: 26,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: row,
      ),
    );
  }
}

class _AttachTab extends StatelessWidget {
  const _AttachTab({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colour = active ? AppColors.brandPrimary : AppColors.textOnGlassDim;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              // The selected tab gets a filled pill, so which category is open
              // is legible without reading the labels.
              color: active
                  ? AppColors.brandPrimary.withValues(alpha: 0.14)
                  : Colors.transparent,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 21, color: colour),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colour,
                    fontSize: 11.5,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
