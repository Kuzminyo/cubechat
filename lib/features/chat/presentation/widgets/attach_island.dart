import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/widgets/floating_glass.dart';
import '../../../../l10n/app_localizations.dart';

/// What the attach island resolved to.
enum AttachChoice { gallery, camera, file }

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
  });

  final AttachChoice selected;
  final ValueChanged<AttachChoice> onPick;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: FloatingGlass(
        borderRadius: 26,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
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
            _AttachTab(
              icon: Icons.insert_drive_file_outlined,
              label: t.attachFile,
              active: selected == AttachChoice.file,
              onTap: () => onPick(AttachChoice.file),
            ),
          ],
        ),
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
