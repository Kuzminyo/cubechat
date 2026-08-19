import 'package:flutter/material.dart';

import '../theme/colors.dart';

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
    // Right edge under the button's right edge, top under its bottom, both
    // pulled back onto the screen if the button sits near an edge.
    final left = (anchor.right - _width).clamp(_pad, overlaySize.width - _width - _pad);
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

class _AnimatedMenuCard<T> extends StatelessWidget {
  const _AnimatedMenuCard({this.items, this.entries});

  final List<AnimatedMenuItem<T>>? items;
  final List<PopupMenuEntry<T>>? entries;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.bgTop.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.glass(0.16)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Material entries carry their own padding and their own tap
            // handling is bypassed, so each is wrapped to report its value.
            if (entries != null)
              for (final entry in entries!)
                if (entry is PopupMenuItem<T>)
                  InkWell(
                    onTap: () => Navigator.of(context).pop(entry.value),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 13,
                      ),
                      child: entry.child ?? const SizedBox.shrink(),
                    ),
                  )
                else
                  entry,
            for (final item in items ?? const <AnimatedMenuItem<Never>>[])
              InkWell(
                onTap: () => Navigator.of(context).pop(item.value),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  child: Row(
                    children: [
                      Icon(item.icon,
                          size: 18,
                          color: item.tone ?? AppColors.brandPrimary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          item.label,
                          style: TextStyle(
                            color: item.tone ?? AppColors.textOnGlass,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
