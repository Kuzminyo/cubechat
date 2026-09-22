import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/util/motion.dart';
import '../../../../l10n/app_localizations.dart';

/// "→A": turn a voice note or a round message into text.
///
/// Kept separate from playback progress: recognition only animates while
/// pending.
///
/// Two shapes. Beside a voice note's waveform it is a small chip, 26 points,
/// in a slot as tall as the play button so the two sit on one line — it was a
/// 44-point tile, taller than everything else in the row, and read as a second
/// button competing with play ("сделай меньше… и централизуй"). Beside a
/// circle it is a round chip outside the circle — the side the circle faces
/// away from, as Telegram draws it — and when tapped it leaves: sliding
/// outward and fading, rightward from somebody else's circle and leftward from
/// ours, because the text is about to appear underneath and a button that
/// stays would only offer the same thing twice. It comes back if recognition
/// fails, so it can be tried again.
///
/// Once the text is there, beside a note or a circle, the button is "↑" and
/// folds the text away; folded, it is "→A" again and brings the same text
/// back without recognising twice ("его можно спрятать, вместо А стрелочка
/// вверх").
class TranscriptionButton extends StatelessWidget {
  const TranscriptionButton({
    super.key,
    required this.loading,
    required this.onPressed,
    this.circle = false,
    this.hidden = false,
    this.flyLeft = false,
    this.expanded = false,
  });

  final bool loading;
  final VoidCallback? onPressed;

  /// Drawn beside a round message rather than inside a voice bubble.
  final bool circle;

  /// Gone, for a circle whose text is on its way.
  final bool hidden;

  /// Which way it leaves: out of the side it sits on.
  final bool flyLeft;

  /// The text is on show: the button is "↑" and folds it away.
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final label = expanded ? t.chatTranscriptHide : t.chatTranscribeAction;
    final enabled = !loading && onPressed != null && !hidden;
    final Widget chip = circle ? _roundChip() : _voiceChip();

    Widget button = Semantics(
      label: label,
      button: true,
      onTap: enabled ? onPressed : null,
      enabled: enabled,
      child: ExcludeSemantics(
        child: Tooltip(
          message: label,
          child: SizedBox(
            // The slot is the hit target; the chip inside is what is drawn.
            // 36 beside a voice note is the play button's height, which is
            // what keeps both on one centre line.
            width: circle ? 44 : 36,
            height: circle ? 44 : 36,
            // A disabled button must still absorb taps: otherwise the circle's
            // playback gesture wins while recognition is pending.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: enabled ? onPressed : () {},
              child: Center(child: chip),
            ),
          ),
        ),
      ),
    );

    if (!circle) return button;

    final reduce = AppMotion.reduced(context);
    final duration = reduce ? Duration.zero : const Duration(milliseconds: 420);
    button = IgnorePointer(
      ignoring: hidden,
      child: AnimatedSlide(
        offset: hidden ? Offset(flyLeft ? -1.4 : 1.4, 0) : Offset.zero,
        duration: duration,
        curve: hidden ? Curves.easeInCubic : Curves.easeOutCubic,
        child: AnimatedScale(
          scale: hidden ? 0.6 : 1,
          duration: duration,
          curve: Curves.easeIn,
          child: AnimatedOpacity(
            opacity: hidden ? 0 : 1,
            duration: duration,
            curve: Curves.easeIn,
            child: button,
          ),
        ),
      ),
    );
    return button;
  }

  Widget _voiceChip() => Container(
        width: 30,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.glass(0.12),
          borderRadius: BorderRadius.circular(9),
        ),
        child: _content(12.5),
      );

  Widget _roundChip() => Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.pane(0.72),
          border: Border.all(color: AppColors.glass(0.16)),
        ),
        child: _content(13),
      );

  // A circle's chip keeps its label while it flies off; the wait is drawn
  // under the circle instead, where the text will land.
  Widget _content(double fontSize) => loading && !hidden
      ? SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            color: AppColors.textOnGlassDim,
          ),
        )
      : expanded
      ? Icon(
          Icons.keyboard_arrow_up_rounded,
          size: fontSize + 7,
          color: AppColors.textOnGlass,
        )
      : Text(
          '→A',
          style: TextStyle(
            fontSize: fontSize,
            height: 1,
            fontWeight: FontWeight.w600,
            color: onPressed == null
                ? AppColors.textOnGlassFaint
                : AppColors.textOnGlass,
          ),
        );
}
