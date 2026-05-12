import 'dart:ui';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/colors.dart';
import '../widgets/aurora_background.dart';

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.body,
    required this.currentIndex,
    required this.onTabChanged,
  });

  final Widget body;
  final int currentIndex;
  final ValueChanged<int> onTabChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final tabs = [
      _TabSpec(icon: Icons.chat_bubble_outline, activeIcon: Icons.chat_bubble, label: t.navChats),
      _TabSpec(icon: Icons.podcasts, activeIcon: Icons.podcasts, label: t.navPeers),
      _TabSpec(icon: Icons.person_outline, activeIcon: Icons.person, label: t.navProfile),
    ];

    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        body: body,
        bottomNavigationBar: _GlassNavBar(
          tabs: tabs,
          currentIndex: currentIndex,
          onTap: onTabChanged,
        ),
      ),
    );
  }
}

class _TabSpec {
  const _TabSpec({required this.icon, required this.activeIcon, required this.label});

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

class _GlassNavBar extends StatelessWidget {
  const _GlassNavBar({
    required this.tabs,
    required this.currentIndex,
    required this.onTap,
  });

  final List<_TabSpec> tabs;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 24,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    for (var i = 0; i < tabs.length; i++)
                      _NavItem(
                        spec: tabs[i],
                        active: i == currentIndex,
                        onTap: () => onTap(i),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.spec, required this.active, required this.onTap});

  final _TabSpec spec;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (child, anim) => ScaleTransition(
                    scale: Tween<double>(begin: 0.85, end: 1).animate(
                      CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
                    ),
                    child: FadeTransition(opacity: anim, child: child),
                  ),
                  child: Icon(
                    active ? spec.activeIcon : spec.icon,
                    key: ValueKey(active),
                    size: 24,
                    color: active ? AppColors.brandPrimary : AppColors.textOnGlassDim,
                  ),
                ),
                const SizedBox(height: 4),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  style: TextStyle(
                    fontSize: 11,
                    color: active ? AppColors.textOnGlass : AppColors.textOnGlassDim,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  ),
                  child: Text(spec.label),
                ),
                const SizedBox(height: 4),
                // Small dot indicator instead of the old gradient pill.
                AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  width: active ? 18 : 0,
                  height: 3,
                  decoration: BoxDecoration(
                    color: AppColors.brandPrimary,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: AppColors.brandPrimary.withValues(alpha: 0.5),
                              blurRadius: 6,
                              spreadRadius: -1,
                            ),
                          ]
                        : null,
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
