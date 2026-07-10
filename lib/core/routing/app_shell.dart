import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/chats/presentation/chats_list_screen.dart';
import '../../l10n/app_localizations.dart';
import '../theme/colors.dart';
import '../widgets/aurora_background.dart';
import '../widgets/unread_badge.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});

  /// Owns the per-tab navigators. Switching tabs goes through
  /// [StatefulNavigationShell.goBranch] rather than a route push, so no screen
  /// is torn down.
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final tabs = [
      _TabSpec(
        icon: Icons.chat_bubble_outline,
        activeIcon: Icons.chat_bubble,
        label: t.navChats,
        showsUnread: true,
      ),
      _TabSpec(icon: Icons.podcasts, activeIcon: Icons.podcasts, label: t.navPeers),
      _TabSpec(icon: Icons.person_outline, activeIcon: Icons.person, label: t.navProfile),
    ];

    return AuroraBackground(
      // The backdrop leans toward whichever tab is open.
      focus: shell.currentIndex.toDouble(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // The bar is deliberately NOT Scaffold.bottomNavigationBar. That slot is
        // a full-width strip in the Scaffold's own layout — the bar becomes a
        // bottom *section* of the page, sized and reserved by the Scaffold, no
        // matter how transparent you paint it. Here the branch content fills the
        // screen and the bar is an overlay on top of it. Between the two there
        // is nothing at all: no wrapper, no fill, no gradient, no blur pane.
        body: Stack(
          children: [
            Positioned.fill(child: shell),
            Positioned(
              // Absolute inset from the screen edges — the only thing this
              // wrapper contributes is position. It paints nothing.
              left: 20,
              right: 20,
              bottom: MediaQuery.paddingOf(context).bottom + 12,
              // Row, not Center: with only `bottom` pinned the child gets loose
              // height, and Center would happily grow to the whole Stack. Row
              // keeps the height tight to the capsule.
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: _GlassPill(
                        tabs: tabs,
                        currentIndex: shell.currentIndex,
                        onTabChanged: (i) => shell.goBranch(
                          i,
                          // Re-tapping a tab pops that branch to its root.
                          initialLocation: i == shell.currentIndex,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabSpec {
  const _TabSpec({
    required this.icon,
    required this.activeIcon,
    required this.label,
    this.showsUnread = false,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;

  /// Whether this tab carries the unread-message counter.
  final bool showsUnread;
}

/// Floating glass island, Telegram-style: it levitates over the content rather
/// than sitting on a coloured plate welded to the bottom edge.
class _GlassPill extends StatefulWidget {
  const _GlassPill({
    required this.tabs,
    required this.currentIndex,
    required this.onTabChanged,
  });

  final List<_TabSpec> tabs;
  final int currentIndex;
  final ValueChanged<int> onTabChanged;

  @override
  State<_GlassPill> createState() => _GlassPillState();
}

class _GlassPillState extends State<_GlassPill>
    with SingleTickerProviderStateMixin {
  /// Big enough to round the ends into a stadium at any bar height.
  static const double _radius = 999;

  static const double _padV = 10;
  static const double _padH = 10;

  /// The square the icon (and the glow behind it) live in.
  static const double _iconBox = 46;
  static const double _iconSize = 24;
  static const double _labelGap = 2;

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: 1,
  );

  late double _from = widget.currentIndex.toDouble();
  late double _to = _from;

  /// How far this hop travels, in tab slots. Drives how much the glow
  /// stretches: a neighbouring tab barely smears, a two-slot jump smears more.
  double get _travel => (_to - _from).abs();

  double get _position => lerpDouble(
        _from,
        _to,
        Curves.easeOutCubic.transform(_c.value),
      )!;

  /// Peaks mid-flight, scaled by how far we're travelling.
  double get _bulge => math.sin(math.pi * _c.value) * math.min(_travel, 1.0);

  double get _stretch => 1 + 0.34 * _bulge;

  /// Conservation of volume, roughly: what it gains in width it gives up in
  /// height.
  double get _squash => 1 - 0.12 * _bulge;

  @override
  void didUpdateWidget(covariant _GlassPill old) {
    super.didUpdateWidget(old);
    if (widget.currentIndex != old.currentIndex) {
      // Retarget from wherever the glow currently is, so hammering the tabs
      // never makes it jump.
      _from = _position;
      _to = widget.currentIndex.toDouble();
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.tabs.length;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_radius),
        // Neutral shadows only. A brand-tinted glow here paints a green halo on
        // the screen around the capsule — exactly the "plate" this bar must not
        // have. Depth comes from two black shadows: one tight contact shadow,
        // one wide ambient one.
        // Kept tight on purpose. A wide, soft drop shadow smears a dark band
        // across the full width beneath the bar, and that band is what reads as
        // "a bottom panel the bar sits in".
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.50),
            blurRadius: 10,
            offset: const Offset(0, 4),
            spreadRadius: -4,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.30),
            blurRadius: 20,
            offset: const Offset(0, 8),
            spreadRadius: -14,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: DecoratedBox(
            decoration: BoxDecoration(
              // Neutral dark glass. The blurred aurora shows through; the panel
              // itself contributes no colour of its own, so it reads as a
              // separate pane of smoked glass rather than a green plate.
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.07),
                  Colors.black.withValues(alpha: 0.52),
                  Colors.black.withValues(alpha: 0.66),
                ],
                stops: const [0, 0.35, 1],
              ),
              borderRadius: BorderRadius.circular(_radius),
              // A crisp hairline is what separates "a pane of glass" from "a
              // darker area of the background".
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.16),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: _padV,
                horizontal: _padH,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final slot = constraints.maxWidth / n;
                  return Stack(
                    children: [
                      // One glow for the whole bar: it slides between slots and
                      // squashes along the direction of travel, which reads as a
                      // single object moving rather than two cross-fading.
                      //
                      // AnimatedBuilder builds no render object, so the
                      // Positioned it returns still lands directly on the Stack.
                      AnimatedBuilder(
                        animation: _c,
                        builder: (context, _) {
                          final w = _iconBox * _stretch;
                          final h = _iconBox * _squash;
                          return Positioned(
                            left: slot * _position + (slot - w) / 2,
                            top: (_iconBox - h) / 2,
                            width: w,
                            height: h,
                            child: const _ActiveGlow(),
                          );
                        },
                      ),
                      Row(
                        children: [
                          for (var i = 0; i < n; i++)
                            Expanded(
                              child: _NavItem(
                                spec: widget.tabs[i],
                                active: i == widget.currentIndex,
                                iconBox: _iconBox,
                                iconSize: _iconSize,
                                labelGap: _labelGap,
                                onTap: () => widget.onTabChanged(i),
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Soft radial halo behind the active tab's icon. A radial gradient rather than
/// a flat disc, so it fades into the glass instead of stamping a hard circle.
class _ActiveGlow extends StatelessWidget {
  const _ActiveGlow();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: RadialGradient(
          colors: [
            AppColors.brandPrimary.withValues(alpha: 0.52),
            AppColors.brandPrimary.withValues(alpha: 0.28),
            AppColors.brandPrimary.withValues(alpha: 0),
          ],
          stops: const [0, 0.58, 1],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.spec,
    required this.active,
    required this.iconBox,
    required this.iconSize,
    required this.labelGap,
    required this.onTap,
  });

  final _TabSpec spec;
  final bool active;
  final double iconBox;
  final double iconSize;
  final double labelGap;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? AppColors.brandPrimary
        : Colors.white.withValues(alpha: 0.88);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: iconBox,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
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
                      size: iconSize,
                      color: color,
                    ),
                  ),
                  if (spec.showsUnread)
                    const Positioned(top: 2, right: 2, child: _UnreadDot()),
                ],
              ),
            ),
            SizedBox(height: labelGap),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.2,
                color: color,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
              child: Text(
                spec.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The unread counter that rides the Chats icon. Scoped to its own [Consumer]
/// so an incoming message repaints the badge, not the whole shell (and with it
/// the aurora and both idle tab branches).
class _UnreadDot extends StatelessWidget {
  const _UnreadDot();

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final unread = ref
            .watch(chatsProvider)
            .fold<int>(0, (sum, chat) => sum + chat.unreadCount);
        if (unread == 0) return const SizedBox.shrink();
        return UnreadBadge(count: unread);
      },
    );
  }
}
