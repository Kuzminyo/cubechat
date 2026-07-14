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
  final overlay =
      rootNav.overlay!.context.findRenderObject() as RenderBox;
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
    color: AppColors.bgTop,
    elevation: 12,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
    ),
    items: items,
  );
}
