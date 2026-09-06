import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/glass.dart';

/// Frosted glass surface — soft white border over an optional backdrop blur.
/// Matches `.glass` / `.glass-strong` from the mockup.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.borderRadius = 20,
    this.strong = false,
    this.onTap,
    this.onLongPress,
    this.blur = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double borderRadius;
  final bool strong;
  final VoidCallback? onTap;

  /// Held down. Where a card carries a second, rarer action than its tap —
  /// moderating a member rather than opening their profile.
  final VoidCallback? onLongPress;

  /// Whether to sample and blur what is behind the card. See
  /// [FloatingGlass.blur] for the full argument; the short version is that a
  /// [BackdropFilter] snapshots the layer below and runs a gaussian over it,
  /// cards do not share that work, and a screen of them is one full blur pass
  /// each per frame.
  ///
  /// Defaults to **off** because every card in this app sits on the aurora —
  /// four wide radial gradients. Blurring a soft gradient returns the same soft
  /// gradient, so the pass costs a phone real heat and returns no pixels. Turn
  /// it on for a card floating over actual content, where there is detail worth
  /// softening.
  final bool blur;

  // `AppBlur.panes` gates every pane in the app on what this phone's GPU was
  // measured able to afford — see [GlassTier]. Stable for the session, so
  // nothing flickers.
  Widget _maybeBlur(Widget child) => blur && AppBlur.panes
      ? BackdropFilter(
          filter: AppBlur.pane,
          child: child,
        )
      : child;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    return Padding(
      padding: margin,
      child: ClipRRect(
        borderRadius: radius,
        child: _maybeBlur(
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                stops: const [0.0, 0.4, 1.0],
                colors: [
                  AppColors.glass(strong ? 0.22 : 0.18),
                  AppColors.glass(0.04),
                  AppColors.glass(0.10),
                ],
              ),
              border: Border.all(
                color: strong
                    ? AppColors.glassBorderStrong
                    : AppColors.glassBorder,
                width: 1,
              ),
              borderRadius: radius,
              // No shadow. The third copy of one, and the third time it has
              // been taken out.
              //
              // [FloatingGlass.shadows] has been an empty list for a long time
              // with a note above it saying why: on a dark backdrop a black
              // halo does not read as height, it reads as grime around the
              // pane, and the halos overlap wherever two panes sit near each
              // other. `MessageIslandGlass` carried its own copy and cost four
              // builds to find, because everybody looked at the blur's edge and
              // the hairline border first.
              //
              // This one is the worst of the three, because these cards nest:
              // the contact profile's actions panel is a card, and inside it
              // sit an info card and two more cards, each with its own soft
              // black halo offset six points down. Stacked inside one
              // translucent island they read as horizontal bands across it —
              // reported as "полоски на острове чужого профиля", and visible on
              // full glass rather than light because a blurred backdrop is
              // smooth enough for a halo to show against.
              //
              // The panes are separated by their fill and their border, which
              // is what the other two concluded. This one now agrees.
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                borderRadius: radius,
                hoverColor: AppColors.glassHover,
                child: Padding(padding: padding, child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
