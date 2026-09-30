import 'package:flutter/material.dart';

import '../theme/colors.dart';
import 'floating_glass.dart';

/// Two or three halves of one screen, picked from a glass island — Contacts |
/// Calls, and Nearby | AirDrop | Files. The highlight slides to the picked
/// part; "reduce motion" makes it jump.
///
/// A capsule, with the highlight a smaller capsule inside it. It was a 14-point
/// corner on a 52-point island with a 10-point highlight: neither a pill nor a
/// card, and the owner asked for the geometry to be fixed. Concentric now —
/// the highlight's radius is the island's minus the inset between them — which
/// is what makes a pill inside a pill look like one object.
class SectionSwitch extends StatelessWidget {
  const SectionSwitch({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelect,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;

  /// A segment's height: the platform's minimum touch target.
  static const double segmentHeight = 44;

  /// The gap between the island's edge and the highlight.
  static const double inset = 4;

  static const double height = segmentHeight + inset * 2;
  static const double outerRadius = height / 2;
  static const double pillRadius = outerRadius - inset;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return FloatingGlass(
      blur: false,
      borderRadius: outerRadius,
      padding: const EdgeInsets.all(inset),
      child: SizedBox(
        height: segmentHeight,
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              AnimatedPositionedDirectional(
                duration: duration,
                curve: Curves.easeOutCubic,
                start: constraints.maxWidth * selected / labels.length,
                width: constraints.maxWidth / labels.length,
                top: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.brandPrimary.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(pillRadius),
                    border: Border.all(
                      color: AppColors.brandPrimary.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < labels.length; i++)
                    Expanded(
                      child: Semantics(
                        selected: i == selected,
                        button: true,
                        child: InkWell(
                          onTap: () => onSelect(i),
                          borderRadius: BorderRadius.circular(pillRadius),
                          child: Container(
                            alignment: Alignment.center,
                            child: AnimatedDefaultTextStyle(
                              duration: duration,
                              curve: Curves.easeOutCubic,
                              style: TextStyle(
                                color: i == selected
                                    ? AppColors.textOnGlass
                                    : AppColors.textOnGlassDim,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                              child: Text(
                                labels[i],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
