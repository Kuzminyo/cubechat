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

/// Bottom nav — three individual glass pills, no connecting bar.
///
/// The previous attempt used one big BackdropFilter, but on a uniform
/// aurora background the blur produces a visible swath that reads as a
/// "panel" even without any fill or border. To kill that effect, each tab
/// gets its own pill-shaped backdrop blur. Between the pills the aurora
/// just continues unmolested — there's nothing for the eye to read as a
/// connecting bar.
class _LiquidGlassNavBar extends StatelessWidget {
  const _LiquidGlassNavBar({
    required this.tabs,
    required this.currentIndex,
    required this.onTap,
  });

  final List<_TabSpec> tabs;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 0; i < tabs.length; i++)
              _NavPill(
                spec: tabs[i],
                active: i == currentIndex,
                onTap: () => onTap(i),
              ),
          ],
        ),
      ),
    );
  }
}

/// A single floating glass pill — one tab button.
class _NavPill extends StatelessWidget {
  const _NavPill({required this.spec, required this.active, required this.onTap});

  final _TabSpec spec;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        // Minimum-presence DecoratedBox: a hairline border + a whisper of
        // fill so the pill is always discernible from the aurora, even when
        // nothing is scrolling underneath. When chats *are* behind the pill,
        // the backdrop blur kicks in and shows them diffused.
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.14),
              width: 1,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(26),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
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
          ),
        ),
      ),
    );
  }
}

