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
          onTabChanged: onTabChanged,
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

/// Floating glass-island bottom nav (Telegram style).
class _GlassNavBar extends StatelessWidget {
  const _GlassNavBar({
    required this.tabs,
    required this.currentIndex,
    required this.onTabChanged,
  });

  final List<_TabSpec> tabs;
  final int currentIndex;
  final ValueChanged<int> onTabChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        // Horizontal-only centering — Row keeps the bar's height tight to
        // its content. (Earlier I used Center here, which expanded
        // vertically and ate the body.)
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: _GlassPill(
                  tabs: tabs,
                  currentIndex: currentIndex,
                  onTabChanged: onTabChanged,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassPill extends StatelessWidget {
  const _GlassPill({
    required this.tabs,
    required this.currentIndex,
    required this.onTabChanged,
  });

  final List<_TabSpec> tabs;
  final int currentIndex;
  final ValueChanged<int> onTabChanged;

  static const double _radius = 30;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_radius),
        // Soft green glow under the bar so it floats off the aurora.
        boxShadow: [
          BoxShadow(
            color: AppColors.brandPrimary.withValues(alpha: 0.18),
            blurRadius: 22,
            offset: const Offset(0, 8),
            spreadRadius: -10,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 10,
            offset: const Offset(0, 5),
            spreadRadius: -8,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: DecoratedBox(
            decoration: BoxDecoration(
              // Green frosted glass: a deep-green base for legibility with a
              // brand-green tint on top, so the whole bar reads green like
              // the mockup rather than neutral dark glass.
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.bgBottom.withValues(alpha: 0.62),
                  AppColors.brandPrimary.withValues(alpha: 0.16),
                ],
              ),
              borderRadius: BorderRadius.circular(_radius),
              border: Border.all(
                color: AppColors.brandPrimary.withValues(alpha: 0.28),
                width: 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Expanded(
                      child: _NavItem(
                        spec: tabs[i],
                        active: i == currentIndex,
                        onTap: () => onTabChanged(i),
                      ),
                    ),
                ],
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
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: BoxDecoration(
            // Active tab sits inside a brighter green "pill" highlight, like
            // the mockup — replaces the old underline indicator.
            color: active
                ? AppColors.brandPrimary.withValues(alpha: 0.22)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: active
                ? Border.all(
                    color: AppColors.brandPrimary.withValues(alpha: 0.35),
                    width: 1,
                  )
                : null,
          ),
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
                  size: 23,
                  color:
                      active ? AppColors.textOnGlass : AppColors.textOnGlassDim,
                ),
              ),
              const SizedBox(height: 4),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                style: TextStyle(
                  fontSize: 11,
                  color: active
                      ? AppColors.textOnGlass
                      : AppColors.textOnGlassDim,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                ),
                child: Text(spec.label, maxLines: 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
