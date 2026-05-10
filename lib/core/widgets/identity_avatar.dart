import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Deterministic gradient avatar from a stable seed (e.g. peer pubkey).
class IdentityAvatar extends StatelessWidget {
  const IdentityAvatar({
    super.key,
    required this.seed,
    required this.label,
    this.size = 44,
    this.online = false,
  });

  final String seed;
  final String label;
  final double size;
  final bool online;

  static const List<List<Color>> _palettes = [
    [Color(0xFF2EDB8F), Color(0xFF7FD9A6)],
    [Color(0xFF34D399), Color(0xFFA3E635)],
    [Color(0xFF7FD9A6), Color(0xFF2EDB8F)],
    [Color(0xFFA3E635), Color(0xFF34D399)],
    [Color(0xFF2EDB8F), Color(0xFFA3E635)],
  ];

  @override
  Widget build(BuildContext context) {
    final palette = _palettes[seed.hashCode.abs() % _palettes.length];
    final initials = _initials(label);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: palette,
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.2),
                width: 1,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              initials,
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.38,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (online)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: size * 0.28,
                height: size * 0.28,
                decoration: BoxDecoration(
                  color: AppColors.online,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.bgDeep, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _initials(String text) {
    final parts = text.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts[1].characters.first).toUpperCase();
  }
}
