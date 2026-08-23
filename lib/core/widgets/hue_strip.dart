import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/theme_controller.dart';
import '../theme/typography.dart';
import 'glass_sheet.dart';
import 'pill_button.dart';

/// Choose a profile colour, or take it back off.
///
/// A sheet rather than a row of swatches: the choice is continuous, it is
/// worth seeing large while it is being made, and it is rare enough that
/// spending a whole panel on it costs nothing the rest of the time.
///
/// [onPick] fires while the finger is still moving — the colour is the thing
/// being judged, so it has to be applied to judge it. Null means "back to the
/// one the identity gives".
Future<void> showHueSheet({
  required BuildContext context,
  required String title,
  required String resetLabel,
  required double? hue,
  required ValueChanged<double?> onPick,
}) {
  var current = hue ?? 210;
  var chosen = hue != null;
  return showGlassSheet<void>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (context, setSheetState) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: AppTypography.heading(size: AppMenu.title)),
            const SizedBox(height: 16),
            HueStrip(
              selected: chosen,
              hue: current,
              onPick: (h) {
                setSheetState(() {
                  current = h;
                  chosen = true;
                });
                onPick(h);
              },
            ),
            const SizedBox(height: 16),
            PillButton(
              label: resetLabel,
              icon: Icons.restart_alt_rounded,
              onTap: () {
                setSheetState(() => chosen = false);
                onPick(null);
              },
            ),
          ],
        ),
      ),
    ),
  );
}

/// The hue wheel, laid flat.
///
/// Used wherever a colour is chosen in this app — the interface theme, your own
/// profile, somebody else's — because all three make the same restricted
/// choice: the wheel picks the *hue* and nothing else. Saturation and lightness
/// stay at the values the hand-made palettes converged on, which is what keeps
/// a label readable at any angle of the wheel; the note at the top of
/// `theme_controller.dart` is where that restraint is explained and where the
/// ratios live.
class HueStrip extends StatelessWidget {
  const HueStrip({
    super.key,
    required this.selected,
    required this.hue,
    required this.onPick,
  });

  /// Whether this is the choice currently in force, which is what the ring
  /// around the disc says.
  final bool selected;

  final double hue;
  final ValueChanged<double> onPick;

  @override
  Widget build(BuildContext context) {
    final preview = AppPalette.hue(hue);
    return Row(
      children: [
        // The disc is the same swatch the preset palettes use: the background
        // the choice will actually wear, with the brand over it. It shows
        // where the slider currently stands.
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [preview.bgTop, preview.bgDeep],
            ),
            border: Border.all(
              color: selected ? Colors.white : AppColors.glass(0.22),
              width: selected ? 2.5 : 1,
            ),
          ),
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [preview.brandPrimary, preview.brandSecondary],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 8,
              // The track is the wheel itself, so the choice is made by
              // looking rather than by reading a number nobody thinks in.
              trackShape: const _HueTrackShape(),
              thumbColor: Colors.white,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              value: hue.clamp(0, 359),
              max: 359,
              onChanged: onPick,
            ),
          ),
        ),
      ],
    );
  }
}

/// A slider track painted as the spectrum.
class _HueTrackShape extends RoundedRectSliderTrackShape {
  const _HueTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final paint = Paint()
      ..shader = const LinearGradient(
        colors: [
          Color(0xFFFF0000),
          Color(0xFFFFFF00),
          Color(0xFF00FF00),
          Color(0xFF00FFFF),
          Color(0xFF0000FF),
          Color(0xFFFF00FF),
          Color(0xFFFF0000),
        ],
      ).createShader(rect);
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
      paint,
    );
  }
}
