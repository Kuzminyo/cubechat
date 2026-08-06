import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// A single levitating pane of smoked glass — the same treatment the floating
/// nav bar uses, offered as a reusable surface so a list of them reads as a
/// row of separate islands over the aurora rather than cards on a plate.
///
/// The recipe is deliberately the nav bar's, not [GlassCard]'s bright frost:
///
///  * a **dark gradient in the palette's colours** (a whisper of its white at
///    the top, its near-black below) so the pane reads as smoked glass rather
///    than a tile. Deep black was the old recipe and it only ever worked on the
///    green theme — see [AppColors.pane];
///  * a **crisp hairline** border, which is what separates "a pane of glass"
///    from "a darker patch of the background";
///  * **two tight black shadows** — a close contact shadow and a slightly
///    wider ambient one, both pulled in with negative spread. A wide, soft
///    drop shadow would smear a dark band under the row, and that band is
///    exactly the "plate" these islands must not sit on.
///
/// Each pane carries its own [BackdropFilter]; a [RepaintBoundary] keeps that
/// blur's repaints from dirtying its neighbours as the list scrolls.
class FloatingGlass extends StatelessWidget {
  const FloatingGlass({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = 18,
    this.onTap,
    this.onLongPressAt,
    this.blur = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final VoidCallback? onTap;

  /// Whether to sample and blur what is behind the pane.
  ///
  /// A [BackdropFilter] is one of the most expensive things a frame can
  /// contain: it snapshots the layer below and runs a gaussian over it, and
  /// panes do not share that work — a list of these is one full blur pass per
  /// row, every frame. On a phone that is the difference between a cool device
  /// and a warm one.
  ///
  /// It is worth paying where the backdrop has detail worth softening: the nav
  /// bar over a scrolling list, a bubble over a conversation. It buys nothing
  /// over the aurora, which is four wide radial gradients — blurring a soft
  /// gradient returns the same soft gradient. Rows sitting on it pass false and
  /// keep the identical fill, border and shadows.
  ///
  /// **Not `BackdropFilter.grouped`, tried and reverted (2026-08-06).** Sharing
  /// one snapshot between the panes on a screen is the documented way to make
  /// several backdrop filters cheap, and it read as the obvious win here —
  /// nav bar, composer, chat header, pinned bar, voice island, all blurring the
  /// same backdrop. On a real phone the app got *less* smooth everywhere, which
  /// is the only measurement that counts and the opposite of the intent. Most
  /// screens carry one or two of these, not five, and a group appears to cost
  /// more than it saves at that count. If this is revisited, measure on a
  /// device first — the reasoning alone has now been wrong once.
  final bool blur;

  /// Long-press reporting the global press point, so a caller can anchor a
  /// popup to the finger. InkWell.onLongPress gives no position, so this rides
  /// an outer detector that only claims the long-press — tap (and its ripple)
  /// still belong to the InkWell.
  final void Function(Offset globalPosition)? onLongPressAt;

  /// The pair of shadows that makes a pane hover: a close contact shadow and a
  /// slightly wider ambient one, both pulled in with negative spread.
  ///
  /// Exposed because not every island can be a [FloatingGlass]. A chat bubble
  /// has to keep its own sender colour, so it builds its own surface — but it
  /// must levitate *identically*, and two hand-tuned shadow lists would drift
  /// apart the first time either is touched.
  static List<BoxShadow> get shadows => [
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
      ];

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);

    final Widget pane = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.glass(0.07),
            AppColors.pane(0.52),
            AppColors.pane(0.66),
          ],
          stops: const [0, 0.35, 1],
        ),
        borderRadius: radius,
        border: Border.all(
          color: AppColors.glass(0.16),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          hoverColor: AppColors.glassHover,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );

    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: shadows,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: blur
            ? BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                child: pane,
              )
            : pane,
      ),
    );

    if (onLongPressAt != null) {
      surface = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (d) => onLongPressAt!(d.globalPosition),
        child: surface,
      );
    }

    return RepaintBoundary(child: surface);
  }
}
