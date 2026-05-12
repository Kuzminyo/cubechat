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
        bottomNavigationBar: _LiquidGlassNavBar(
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

/// Liquid-glass bottom nav.
///
/// Composition:
///   1. heavy BackdropFilter blur (real frosted glass — chat content is
///      visible through it, just diffused)
///   2. soft white→transparent vertical gradient (lens refraction)
///   3. 1px upper specular highlight (the bright "edge of the glass")
///   4. 1px lower inner shadow (the dark "back edge" — sells thickness)
///   5. hairline outer border + outer drop shadow
///   6. tab content on top
class _LiquidGlassNavBar extends StatelessWidget {
  const _LiquidGlassNavBar({
    required this.tabs,
    required this.currentIndex,
    required this.onTap,
  });

  final List<_TabSpec> tabs;
  final int currentIndex;
  final ValueChanged<int> onTap;

  static const double _radius = 30;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: DecoratedBox(
        // Outer drop shadow lives outside the clip so it isn't blurred away.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_radius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_radius),
          child: Stack(
            children: [
              // (1) Frosted-glass blur of whatever is behind the bar.
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                  child: const SizedBox.shrink(),
                ),
              ),

              // (2) Lens refraction tint — top of the glass catches more light.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.14),
                        Colors.white.withValues(alpha: 0.03),
                        Colors.white.withValues(alpha: 0.06),
                      ],
                      stops: const [0.0, 0.55, 1.0],
                    ),
                  ),
                ),
              ),

              // (3) Bright specular line along the top edge — the signature
              //     liquid-glass "wet rim".
              Positioned(
                top: 0,
                left: 1,
                right: 1,
                height: 1.2,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0.0),
                        Colors.white.withValues(alpha: 0.55),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),

              // (4) Subtle dark edge along the bottom — sells the thickness
              //     of the glass.
              Positioned(
                bottom: 0,
                left: 1,
                right: 1,
                height: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.18),
                  ),
                ),
              ),

              // (5) Outer hairline border.
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(_radius),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.18),
                        width: 1,
                      ),
                    ),
                  ),
                ),
              ),

              // (6) Tab content.
              SafeArea(
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
            ],
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
          borderRadius: BorderRadius.circular(22),
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
                // Small dot indicator under active tab.
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
                              color: AppColors.brandPrimary.withValues(alpha: 0.55),
                              blurRadius: 8,
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
