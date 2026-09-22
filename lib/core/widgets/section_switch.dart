import 'package:flutter/material.dart';

import '../theme/colors.dart';
import 'floating_glass.dart';

/// Two or three halves of one screen, picked from a glass island — Contacts |
/// Calls, and Nearby | AirDrop | Files. The highlight slides to the picked
/// part; "reduce motion" makes it jump.
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

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return FloatingGlass(
      blur: false,
      borderRadius: 14,
      padding: const EdgeInsets.all(4),
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
                  borderRadius: BorderRadius.circular(10),
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
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 44),
                          padding: const EdgeInsets.symmetric(vertical: 9),
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
    );
  }
}
