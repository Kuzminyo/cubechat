import 'dart:ui' show ImageFilter;

/// The frosted-glass blur, in one place.
///
/// Measured, not guessed. Diagnostics reports frame cost split by thread, and
/// on a mid-range Android scrolling a chat it read:
///
///     build  (CPU / Dart)   avg 1.2   p90  1.7 ms
///     raster (GPU)          avg 6.3   p90 11.7 ms
///
/// The UI thread is doing essentially nothing; the GPU is seven times more
/// expensive and its p90 is past the 8.3 ms a 120 Hz frame gets. Two earlier
/// rounds of work on this went entirely into the 1.2 ms column — real
/// inefficiencies, correctly removed, and the phone was exactly as warm
/// afterwards, because that was never where the time was going.
///
/// What is on the GPU is this: a `BackdropFilter` snapshots what is behind it
/// and runs a gaussian over it, and three of them are permanently on screen in
/// a conversation — the nav bar, the chat header and the composer. Each re-runs
/// on every frame the content behind it moves, which during a scroll is every
/// frame. It is identical work on both platforms, which is exactly why the heat
/// was identical on both platforms.
///
/// [sigma] is 14 rather than 30 because of what sits *over* the blur. These
/// panes are filled at 52–66% opacity; the blurred backdrop is looked at
/// through that, and past roughly a dozen pixels of radius a gaussian of a
/// mostly-hidden backdrop stops being distinguishable — the highlights have
/// already smeared into flat colour. The frost reads the same and the cost is
/// roughly halved.
///
/// This is a knob, deliberately. If a surface ever needs more, give that
/// surface its own number and say why; do not raise this one, or the cost
/// silently returns everywhere at once.
class AppBlur {
  const AppBlur._();

  /// Standard pane blur.
  static const double sigma = 14;

  /// Ready-made filter, so no call site has to remember to pass the same value
  /// to both axes.
  ///
  /// `final`, not a getter: one instance for the whole app rather than a fresh
  /// one per build, so the layer comparison that decides whether a backdrop has
  /// to be re-filtered sees the same object each frame.
  static final ImageFilter pane =
      ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
}
