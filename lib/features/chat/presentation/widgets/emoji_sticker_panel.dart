import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../stickers/presentation/sticker_grid.dart';
import 'emoji_picker_sheet.dart';

/// How tall the keyboard on this phone is, remembered from the last time it was
/// up.
///
/// The panel takes the keyboard's place, so it has to be the keyboard's size —
/// and the only way to know that is to have seen it. Every field in the app
/// reports what it measures through [observe], so by the time anybody opens the
/// panel the number is usually a real one; [fallback] covers the case where the
/// very first thing they do in a fresh launch is press the smiley.
abstract final class KeyboardHeight {
  static const double fallback = 300;

  /// Anything below this is not a keyboard — it is an autocomplete strip, an
  /// accessory bar, or the tail of a dismissal animation.
  static const double _floor = 120;

  static double _seen = 0;

  static void observe(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset > _floor && inset != _seen) _seen = inset;
  }

  static double get value => _seen > 0 ? _seen : fallback;
}

/// Emoji on one tab, stickers on the other, sized and placed to *be* the
/// keyboard rather than to cover it.
///
/// This started as a modal sheet, which is the wrong shape for it: a sheet
/// floats over the conversation with its own scrim and pushes the field it is
/// typing into off the screen, so you cannot see what you are writing. Docked
/// under the composer it behaves the way every messenger's does — the field
/// stays put, the panel occupies exactly the space the keyboard had, and the
/// button that opened it turns into the one that brings the keyboard back.
class EmojiStickerPanel extends StatefulWidget {
  const EmojiStickerPanel({
    super.key,
    required this.height,
    required this.onEmoji,
    this.onSticker,
    this.onCreateSticker,
    this.startOnStickers = false,
  });

  final double height;
  final ValueChanged<String> onEmoji;

  /// Null where a picture cannot be sent — the panel is then emoji only, and
  /// the sticker tab is not offered rather than being offered and refusing.
  final void Function(String path, String? emoji)? onSticker;
  final VoidCallback? onCreateSticker;
  final bool startOnStickers;

  @override
  State<EmojiStickerPanel> createState() => _EmojiStickerPanelState();
}

class _EmojiStickerPanelState extends State<EmojiStickerPanel> {
  late bool _stickers = widget.startOnStickers && widget.onSticker != null;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final stickers = widget.onSticker != null;
    // An island, like everything else that floats over the aurora here: margins
    // on three sides, rounded corners, the pane's own glass. A full-width plate
    // welded to the bottom edge was the one surface in the app that looked
    // borrowed from somewhere else.
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Container(
        height: widget.height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.pane(0.86),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: AppColors.glass(0.14)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.32),
              blurRadius: 20,
              offset: const Offset(0, 8),
              spreadRadius: -12,
            ),
          ],
        ),
        child: Column(
          children: [
            if (stickers)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
                child: Row(
                  children: [
                    _Tab(
                      label: t.emojiTab,
                      icon: Icons.emoji_emotions_outlined,
                      active: !_stickers,
                      onTap: () => setState(() => _stickers = false),
                    ),
                    const SizedBox(width: 8),
                    _Tab(
                      label: t.attachStickers,
                      icon: Icons.auto_awesome_outlined,
                      active: _stickers,
                      onTap: () => setState(() => _stickers = true),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _stickers
                  ? StickerGrid(
                      onPick: widget.onSticker!,
                      onCreate: widget.onCreateSticker,
                    )
                  : EmojiPane(onPick: widget.onEmoji),
            ),
          ],
        ),
      ),
    );
  }
}

/// The panel, sized against the keyboard and animated in and out.
///
/// The height is deliberately `keyboard height − whatever the keyboard is
/// currently taking`, which is what makes the swap between the two look like
/// one thing turning into the other rather than two things fighting: while the
/// keyboard slides up, this shrinks by exactly as much as it grows, so the
/// composer above never moves. [visible] drives the other case — opening or
/// closing the panel with no keyboard involved — over its own curve.
class AnimatedEmojiStickerPanel extends StatelessWidget {
  const AnimatedEmojiStickerPanel({
    super.key,
    required this.visible,
    required this.onEmoji,
    this.onSticker,
    this.onCreateSticker,
    this.startOnStickers = false,
  });

  final bool visible;
  final ValueChanged<String> onEmoji;
  final void Function(String path, String? emoji)? onSticker;
  final VoidCallback? onCreateSticker;
  final bool startOnStickers;

  /// Also how long the caller should wait before taking the panel out of the
  /// tree, so the fold is seen rather than cut off.
  static const Duration motion = Duration(milliseconds: 240);

  @override
  Widget build(BuildContext context) {
    final full = KeyboardHeight.value;
    return TweenAnimationBuilder<double>(
      // Only the open/close half is tweened. The keyboard half is *not*: the
      // system is already animating that inset, and running a second curve over
      // the top of it is what makes a panel swap look like a bounce.
      tween: Tween<double>(end: visible ? 1 : 0),
      duration: motion,
      curve: Curves.easeOutCubic,
      builder: (context, open, child) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: open.clamp(0.0, 1.0),
          child: child,
        ),
      ),
      child: EmojiStickerPanel(
        height: full,
        startOnStickers: startOnStickers,
        onEmoji: onEmoji,
        onSticker: onSticker,
        onCreateSticker: onCreateSticker,
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
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
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: active
                  ? AppColors.brandPrimary.withValues(alpha: 0.14)
                  : Colors.transparent,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 17, color: colour),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: colour,
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
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
