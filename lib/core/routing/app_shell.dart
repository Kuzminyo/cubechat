import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/chats/presentation/chats_list_screen.dart';
import '../../features/profile/data/nav_bar_controller.dart';
import '../../l10n/app_localizations.dart';
import '../theme/colors.dart';
import '../widgets/aurora_background.dart';
import '../widgets/bar_glass.dart';
import '../widgets/unread_badge.dart';

/// Everything the bar needs to draw one destination.
///
/// Keyed by [NavDestination] rather than by position, because position is now
/// the user's to decide — see [NavBarController]. The router's branch order is
/// still the enum's order and still the contract; this only says how each one
/// looks.
///
/// Contacts before Nearby in that enum, and deliberately: people you already
/// know sit next to Chats, and the radio-range list — the one you only open
/// when meeting somebody new — starts further out. That is the default the
/// user is now free to overrule.
NavTabSpec tabSpecFor(NavDestination destination, AppLocalizations t) =>
    switch (destination) {
      NavDestination.chats => NavTabSpec(
          icon: Icons.chat_bubble_outline_rounded,
          activeIcon: Icons.chat_bubble_rounded,
          label: t.navChats,
          showsUnread: true,
        ),
      NavDestination.contacts => NavTabSpec(
          icon: Icons.contacts_rounded,
          activeIcon: Icons.contacts_rounded,
          label: t.navContacts,
        ),
      NavDestination.peers => NavTabSpec(
          icon: Icons.radar_rounded,
          activeIcon: Icons.radar_rounded,
          label: t.navPeers,
        ),
      NavDestination.map => NavTabSpec(
          icon: Icons.map_rounded,
          activeIcon: Icons.map_rounded,
          label: t.navMap,
        ),
      NavDestination.profile => NavTabSpec(
          icon: Icons.person_outline_rounded,
          activeIcon: Icons.person_rounded,
          label: t.navProfile,
        ),
    };

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell});

  /// Owns the per-tab navigators. Switching tabs goes through
  /// [StatefulNavigationShell.goBranch] rather than a route push, so no screen
  /// is torn down.
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final layout = ref.watch(navBarControllerProvider);
    final tabs = [for (final d in layout.shown) tabSpecFor(d, t)];
    // Where the branch we are standing on sits on *this* bar. Null when its tab
    // has been hidden — allowed, and resolved the same way the strip resolves
    // it (see the container builder in app_router.dart): fall back to the first
    // tab rather than refuse the edit.
    final currentIndex = layout.positionOf(shell.currentIndex) ?? 0;

    // The system back gesture goes to Chats before it leaves the app.
    //
    // There was nothing here at all, so a swipe back from Contacts, Nearby, the
    // map or the profile closed cubechat outright — on a phone where back *is*
    // a swipe from the edge, that is the gesture people use to mean "out of
    // this screen", and it was throwing them out of the application instead.
    // Chats is the first branch and the one the app opens on, so it is where
    // "back" means; from there the gesture keeps its usual meaning and the app
    // does close.
    return PopScope<void>(
      canPop: shell.currentIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || shell.currentIndex == 0) return;
        shell.goBranch(0);
      },
      child: AuroraBackground(
      // The backdrop leans toward whichever tab is open — by where it sits on
      // the bar, not by its branch index, so the light still travels with the
      // finger once the tabs have been reordered.
      focus: tabs.length < 2 ? 1.0 : currentIndex * 2 / (tabs.length - 1),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // The keyboard must cover the bar, not push it.
        //
        // With the default (true) the Scaffold shrinks its body by the keyboard
        // height, and since the bar is pinned to the *bottom of that body* it
        // rode up and sat on top of the keyboard — tapping the chat search made
        // a nav bar appear in the middle of the screen. It is an overlay on the
        // content, so it belongs at the bottom of the screen, full stop.
        //
        // Nothing in a tab branch relies on the resize: every text field in one
        // sits at the top (the Chats and Contacts search), and the screens with
        // low-sitting inputs — the chat composer, the contact card — are pushed
        // routes with their own Scaffolds, which still resize normally.
        resizeToAvoidBottomInset: false,
        // The bar is deliberately NOT Scaffold.bottomNavigationBar. That slot is
        // a full-width strip in the Scaffold's own layout — the bar becomes a
        // bottom *section* of the page, sized and reserved by the Scaffold, no
        // matter how transparent you paint it. Here the branch content fills the
        // screen and the bar is an overlay on top of it. Between the two there
        // is nothing at all: no wrapper, no fill, no gradient, no blur pane.
        body: Stack(
          children: [
            // The strip of branches, and the drag between them, both live in
            // BranchContainer — it is the widget that holds the four screens,
            // so it is the only one that can move them as a strip rather than
            // animate over the top of them.
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
                        currentIndex: currentIndex,
                        // The bar speaks positions and the shell speaks
                        // branches. This is the one place the two are
                        // translated, so a reordered bar cannot send a tap to
                        // somebody else's screen.
                        onTabChanged: (i) => shell.goBranch(
                          layout.branches[i],
                          // Re-tapping a tab pops that branch to its root.
                          initialLocation: i == currentIndex,
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
      ),
    );
  }
}

class NavTabSpec {
  const NavTabSpec({
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

  final List<NavTabSpec> tabs;
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

    // The bar's own surface, extracted so the media sheet can be the same pane
    // rather than a copy of it that drifts. See [BarGlass] for why each part of
    // the recipe is there.
    return BarGlass(
      radius: _radius,
      padding: const EdgeInsets.symmetric(vertical: _padV, horizontal: _padH),
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

  final NavTabSpec spec;
  final bool active;
  final double iconBox;
  final double iconSize;
  final double labelGap;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.brandPrimary : AppColors.ink(0.88);

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
                        CurvedAnimation(
                          parent: anim,
                          curve: Curves.easeOutBack,
                        ),
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
                fontSize: 10.5,
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
