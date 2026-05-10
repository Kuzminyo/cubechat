import 'package:flutter/material.dart';

import '../theme/colors.dart';

class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    this.icon,
    this.active = false,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: active
                ? Colors.white.withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.10),
            border: Border.all(
              color: active
                  ? Colors.white.withValues(alpha: 0.30)
                  : Colors.white.withValues(alpha: 0.15),
            ),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: AppColors.textOnGlass),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textOnGlass,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
