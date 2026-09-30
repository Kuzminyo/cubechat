import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/glass.dart';
import '../theme/typography.dart';

/// A small rounded popup menu anchored at [globalPosition], the way a long-press
/// menu behaves in Telegram.
///
/// It is pushed on the **root** navigator, so it floats above the app's overlay
/// chrome — most importantly the floating nav bar, which lives inside the tab
/// shell. A menu shown from a shell branch's own navigator renders *underneath*
/// that bar; presenting it here is what puts it back on top.
///
/// Returns the value of the tapped entry, or null if dismissed.
/// How menus open and close.
///
/// Material's default is 300 ms in and an instant snap out, which is what made
/// every menu in the app feel like it was deleted rather than dismissed. Both
/// ends are eased here, and the whole app uses this one style so a long-press
/// menu, the overflow menu and a sheet all decelerate alike.
const AnimationStyle glassMenuMotion = AnimationStyle(
  duration: Duration(milliseconds: 260),
  reverseDuration: Duration(milliseconds: 200),
  curve: Curves.easeOutCubic,
  reverseCurve: Curves.easeInCubic,
);

Future<T?> showContextPopup<T>({
  required BuildContext context,
  required Offset globalPosition,
  required List<PopupMenuEntry<T>> items,
}) {
  final rootNav = Navigator.of(context, rootNavigator: true);
  final overlaySize =
      (rootNav.overlay!.context.findRenderObject() as RenderBox).size;
  // Anchored on the press point rather than a button's rect: this one is opened
  // by a long press, so a 1x1 rect at the finger is the whole anchor there is.
  return rootNav.push(
    _AnimatedMenuRoute<T>(
      anchor: globalPosition & const Size(1, 1),
      overlaySize: overlaySize,
      entries: items,
    ),
  );
}

/// One row in [showAnimatedMenu].
class AnimatedMenuItem<T> {
  const AnimatedMenuItem({
    required this.value,
    required this.icon,
    required this.label,
    this.tone,
  });

  final T value;
  final IconData icon;
  final String label;

  /// A colour for a destructive row, or null for the ordinary brand tint.
  final Color? tone;
}

/// A drop menu that is guaranteed to animate both ways.
///
/// The Material [PopupMenuButton] takes a [popUpAnimationStyle], but its
/// content appeared and vanished without any motion the eye could catch — the
/// open is subtle and the close is hidden the instant a tapped entry pushes a
/// screen over it. This is a route we own end to end, so a scale-and-fade
/// plays on the way in *and* on the way out, growing from the corner the anchor
/// sits in.
///
/// [anchor] is the button's rect in global coordinates; the menu hangs from its
/// bottom edge, pushed left so its right edge lines up with the button's, and
/// clamped to stay on screen.
Future<T?> showAnimatedMenu<T>({
  required BuildContext context,
  required Rect anchor,
  required List<AnimatedMenuItem<T>> items,
}) {
  final rootNav = Navigator.of(context, rootNavigator: true);
  final overlaySize =
      (rootNav.overlay!.context.findRenderObject() as RenderBox).size;
  return rootNav.push(
    _AnimatedMenuRoute<T>(
      anchor: anchor,
      overlaySize: overlaySize,
      items: items,
    ),
  );
}

class _AnimatedMenuRoute<T> extends PopupRoute<T> {
  _AnimatedMenuRoute({
    required this.anchor,
    required this.overlaySize,
    this.items,
    this.entries,
  }) : assert(items != null || entries != null);

  final Rect anchor;
  final Size overlaySize;

  /// Rows described declaratively — the shape new call sites use.
  final List<AnimatedMenuItem<T>>? items;

  /// Ready-made Material entries, for the call sites that already build them.
  /// Rendered as-is inside our own card so those menus animate without every
  /// one of them being rewritten.
  final List<PopupMenuEntry<T>>? entries;

  int get _rowCount => items?.length ?? entries!.length;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss menu';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 210);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 170);

  static const double _width = 244;
  static const double _pad = 8;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // A button hangs its menu from its right edge; a press point opens it at
    // the finger. Told apart by the anchor's width — a real control has one, a
    // long press is a 1x1 rect at the touch. Using the button rule for both is
    // what put a long-press menu in the middle of the screen instead of under
    // the row that was held.
    final fromButton = anchor.width > 2;
    final wanted = fromButton ? anchor.right - _width : anchor.left - 24;
    final left = wanted.clamp(_pad, overlaySize.width - _width - _pad);
    final top = (anchor.bottom + 4)
        .clamp(_pad, overlaySize.height - _pad - _rowCount * 48.0 - 12);
    return Stack(
      children: [
        Positioned(
          left: left.toDouble(),
          top: top.toDouble(),
          width: _width,
          child: _AnimatedMenuCard<T>(items: items, entries: entries),
        ),
      ],
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        // Grows from the top-right corner, where the button is.
        alignment: Alignment.topRight,
        scale: Tween<double>(begin: 0.88, end: 1).animate(curved),
        child: child,
      ),
    );
  }
}

/// The surface every menu in the app is drawn on — the drop menus here and
/// the contact profile's actions panel alike.
///
/// That panel was a glass card of its own (28-point corners, white icons, bold
/// labels, a chevron on every row) beside flat dark drop menus with green
/// icons, and three menus open side by side looked like three apps. The owner
/// picked the panel's look "but not at that scale": so every menu is glass now
/// — the panel's blurred frost — at the drop menus' compact size.
class AppMenuSurface extends StatelessWidget {
  const AppMenuSurface({super.key, required this.child});

  static const double radius = 22;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    Widget pane = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        // A menu opens over content, not over the aurora, so it is a little
        // denser than a card: the frost has to hold its words over a photo.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.pane(0.58), AppColors.pane(0.76)],
        ),
      ),
      // The same soft corner light as the tiles, so a menu is glass and not
      // a dark slab.
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: shape,
          gradient: RadialGradient(
            center: const Alignment(-1.0, -1.2),
            radius: 1.6,
            colors: [AppColors.glass(0.12), AppColors.glass(0)],
          ),
          border: Border.all(color: AppColors.glass(0.20)),
        ),
        child: child,
      ),
    );
    // Blurred where the phone was measured able to afford it (see
    // [GlassTier]); a menu is open for a moment, so it is the cheapest place
    // in the app to spend a gaussian.
    if (AppBlur.panes) {
      pane = BackdropFilter(filter: AppBlur.pane, child: pane);
    }
    return Material(
      color: Colors.transparent,
      child: ClipRRect(borderRadius: shape, child: pane),
    );
  }
}

/// One row of a menu: icon, label, and — when a row explains itself — a line
/// under it. [tone] colours a destructive row, icon and label. [chevron] for a
/// row that opens something further rather than acting at once.
///
/// The actions panel's row, white icon and semibold label, at the drop menus'
/// height — "like the actions, just not that huge".
class AppMenuRow extends StatelessWidget {
  const AppMenuRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.tone,
    this.chevron = false,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final Color? tone;
  final bool chevron;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    final ink = tone ?? AppColors.textOnGlass;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: AppMenu.rowIcon + 2, color: ink),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: ink,
                      fontSize: AppMenu.rowLabel,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: AppColors.textOnGlassDim,
                        fontSize: AppMenu.rowSubtitle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (chevron)
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: ink.withValues(alpha: 0.5),
              ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedMenuCard<T> extends StatelessWidget {
  const _AnimatedMenuCard({this.items, this.entries});

  final List<AnimatedMenuItem<T>>? items;
  final List<PopupMenuEntry<T>>? entries;

  @override
  Widget build(BuildContext context) {
    return AppMenuSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        // Stretch, not the default centre. Every row here is a Row with
        // `mainAxisSize.min`, so under a centring Column each one shrank to
        // its content and floated to the middle — icons and labels down the
        // centre line instead of a left-aligned list. Stretching makes each
        // row fill the card, which is what puts the icons back in a column
        // at the leading edge.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Material entries carry their own padding and their own tap
          // handling is bypassed, so each is wrapped to report its value.
          if (entries != null)
            for (final entry in entries!)
              if (entry is PopupMenuItem<T>)
                InkWell(
                  onTap: () => Navigator.of(context).pop(entry.value),
                  child: Padding(
                    // [AppMenuRow]'s own padding, so a Material entry and a
                    // plain item line up.
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: entry.child ?? const SizedBox.shrink(),
                  ),
                )
              else
                entry,
          for (final item in items ?? const <AnimatedMenuItem<Never>>[])
            AppMenuRow(
              icon: item.icon,
              label: item.label,
              tone: item.tone,
              onTap: () => Navigator.of(context).pop(item.value),
            ),
        ],
      ),
    );
  }
}
