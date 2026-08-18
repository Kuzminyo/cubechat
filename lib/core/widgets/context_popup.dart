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
  final overlay = rootNav.overlay!.context.findRenderObject() as RenderBox;
  // A 1x1 anchor rect at the press point; showMenu grows the menu from here and
  // keeps it on screen. Coordinates are global, which is exactly the root
  // overlay's coordinate space.
  final position = RelativeRect.fromRect(
    globalPosition & const Size(1, 1),
    Offset.zero & overlay.size,
  );
  return showMenu<T>(
    context: rootNav.context,
    position: position,
    // Translucent rather than the flat opaque fill this used to have. Every
    // other surface in the app is smoked glass over the aurora, and an opaque
    // slab dropped into the middle of that reads as borrowed from another
    // application.
    //
    // Not a true frosted pane: showMenu owns its own surface, so there is
    // nowhere to hang a BackdropFilter without replacing the route wholesale —
    // and with it showMenu's anchoring and on-screen clamping, which is
    // fiddly work that wants checking on a real screen. Translucency plus the
    // hairline gets most of the way there and risks nothing.
    color: AppColors.bgTop.withValues(alpha: 0.92),
    elevation: 16,
    shadowColor: Colors.black,
    popUpAnimationStyle: glassMenuMotion,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: AppColors.glass(0.16)),
    ),
    items: items,
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
    required this.items,
  });

  final Rect anchor;
  final Size overlaySize;
  final List<AnimatedMenuItem<T>> items;

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
        .clamp(_pad, overlaySize.height - _pad - items.length * 48.0 - 12);
    return Stack(
      children: [
        Positioned(
          left: left.toDouble(),
          top: top.toDouble(),
          width: _width,
          child: _AnimatedMenuCard<T>(items: items),
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
  const _AnimatedMenuCard({required this.items});

  final List<AnimatedMenuItem<T>> items;

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
            for (final item in items)
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
