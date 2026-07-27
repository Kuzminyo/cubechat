import 'package:flutter/material.dart';

/// Where iOS should point the share sheet.
///
/// UIKit presents `UIActivityViewController` as a popover and refuses to guess
/// where it came from: with no anchor — or an empty one — it raises
///
/// ```
/// sharePositionOrigin: argument must be set, {{0, 0}, {0, 0}} must be
/// non-zero and within coordinate space of source view
/// ```
///
/// and the share fails outright. This is easy to under-fix. The obvious reading
/// is "iPad needs an anchor", so a nullable helper that returns null before
/// layout looks harmless — but null *is* the empty rect as far as the platform
/// channel is concerned, and the raise happens on iPhone too. So this never
/// returns null: if the widget cannot be measured, it falls back to a small
/// rect in the top-trailing corner, where a share control almost always is, and
/// the sheet still opens.
///
/// [key] is for a control that lives somewhere else in the tree from the code
/// invoking the share — an `AppBar` action, say, whose own `BuildContext` the
/// handler has no reference to.
Rect shareAnchorFor(BuildContext context, {GlobalKey? key}) {
  final screen = MediaQuery.sizeOf(context);
  final target = key?.currentContext ?? context;

  final box = target.findRenderObject();
  if (box is RenderBox && box.hasSize && box.attached) {
    final size = box.size;
    if (size.width > 0 && size.height > 0) {
      try {
        final rect = box.localToGlobal(Offset.zero) & size;
        // A control scrolled off-screen measures fine but sits outside the
        // source view, which the platform rejects for the same reason an empty
        // rect is rejected.
        if (_within(rect, screen)) return rect;
      } catch (_) {
        // Not currently attached to a live pipeline — fall through.
      }
    }
  }

  return _fallback(screen);
}

bool _within(Rect rect, Size screen) =>
    rect.left >= 0 &&
    rect.top >= 0 &&
    rect.right <= screen.width &&
    rect.bottom <= screen.height;

/// A 40×40 square inset from the top-trailing corner, clamped so it stays
/// inside even a very small window.
Rect _fallback(Size screen) {
  const side = 40.0;
  final left = (screen.width - side - 16).clamp(0.0, screen.width - 1);
  final top = 48.0.clamp(0.0, screen.height - 1);
  final width = side.clamp(1.0, screen.width - left);
  final height = side.clamp(1.0, screen.height - top);
  return Rect.fromLTWH(left, top, width, height);
}
