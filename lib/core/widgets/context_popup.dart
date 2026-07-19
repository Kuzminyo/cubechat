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
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
    ),
    items: items,
  );
}
