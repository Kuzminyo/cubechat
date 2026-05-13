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

/// One floating glass pill containing all the tabs.
///
/// Telegram-style: a single rounded container with a dark translucent fill
/// and a hairline border. Chat content above shows through, diffused by the
/// backdrop blur. The dark tint (rather than white) keeps the bar from
/// going milky on the dark aurora theme.
class _GlassNavBar extends StatelessWidget {
  const _GlassNavBar({
    required this.tabs,
    required this.currentIndex,
    required this.onTabChanged,
  });

  final List<_TabSpec> tabs;
  final int currentIndex;
  final ValueChanged<int> onTabChanged;

  static const double _radius = 36;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_radius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.40),
              blurRadius: 30,
              offset: const Offset(0, 12),
              spreadRadius: -6,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_radius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: DecoratedBox(
              decoration: BoxDecoration(
                // Dark glass tint — sits slightly darker than aurora rather
                // than lighter, which is what makes Telegram's bar read as
                // glass rather than as a panel.
                color: Colors.black.withValues(alpha: 0.32),
                borderRadius: BorderRadius.circular(_radius),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.14),
                  width: 1,
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
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
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
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
    );
  }
}
