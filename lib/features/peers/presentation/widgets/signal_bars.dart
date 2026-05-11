import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';

class SignalBars extends StatelessWidget {
  const SignalBars({super.key, required this.strength});

  /// 0..1
  final double strength;

  @override
  Widget build(BuildContext context) {
    const totalBars = 4;
    final activeBars = (strength * totalBars).round().clamp(0, totalBars);
    return SizedBox(
      width: 28,
      height: 18,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: List.generate(totalBars, (i) {
          final isActive = i < activeBars;
          final h = 4.0 + i * 3.5;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              width: 3,
              height: h,
              decoration: BoxDecoration(
                color: isActive
                    ? AppColors.brandPrimary
                    : Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
                boxShadow: isActive
                    ? [
                        BoxShadow(
                          color: AppColors.brandPrimary.withValues(alpha: 0.5),
                          blurRadius: 4,
                          spreadRadius: -1,
                        ),
                      ]
                    : null,
              ),
            ),
          );
        }),
      ),
    );
  }
}
