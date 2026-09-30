import 'package:flutter/material.dart';

/// Pages of one screen moving as a strip, the way the main tabs do: they sit
/// side by side, and picking one slides the old one out as the new one slides
/// in, a full width each. Nearby | AirDrop | Files, and Contacts | Calls.
///
/// Both used to bring only the new page in — 22% of the width with a fade —
/// while the old one simply vanished, which read as a cut with a flourish
/// rather than as moving along a row. Translation only: an opacity would cost
/// an offscreen pass over a full page each frame, a translation moves an
/// already painted layer (see [BranchContainer] for the same argument).
class StripPageSlide extends StatelessWidget {
  const StripPageSlide({
    super.key,
    required this.animation,
    required this.from,
    required this.child,
    this.leaving = false,
  });

  final Animation<double> animation;

  /// +1 when the new page is to the right of the old one, -1 to the left.
  final double from;

  /// This is the old page on its way out.
  final bool leaving;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, inner) {
        final t =
            reduced ? 1.0 : Curves.easeOutCubic.transform(animation.value);
        final dx = leaving ? -t * from * width : (1 - t) * from * width;
        return Transform.translate(offset: Offset(dx, 0), child: inner);
      },
    );
  }
}
