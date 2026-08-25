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
/// It went to 9 for an hour on 2026-08-17 and came back, not because 9 was
/// wrong but because it was shipped in the same build as a refresh-rate change
/// that made the app barely usable. Reverting one unverified change while
/// leaving another on top of it is not a revert. If this is lowered again, do
/// it on its own and measure it on its own.
///
/// This is a knob, deliberately. If a surface ever needs more, give that
/// surface its own number and say why; do not raise this one, or the cost
/// silently returns everywhere at once.
class AppBlur {
  const AppBlur._();

  /// Standard pane blur.
  ///
  /// 9 since 2026-08-25, on its own and in a build carrying nothing else —
  /// which is what the note above asks for and what was not done last time.
  ///
  /// The prompt was a second phone, a mid-range Mali, reading:
  ///
  ///     build  (CPU / Dart)   avg 2.7   p90  5.1 ms
  ///     raster (GPU)          avg 11.6  p90 17.3 ms
  ///     484 of 2726 frames over 16.7 ms · GPU-bound
  ///
  /// The first phone measured on the same day sat at raster p90 3.4 ms and
  /// never noticed any of this, which is the whole reason a second device was
  /// worth asking for: this cost is invisible until the GPU is slower than the
  /// one it was tuned on.
  ///
  /// MEASURED, AND IT DID NOT WORK. Back to 14 on 2026-08-25. The same phone,
  /// same screen, blur at 9:
  ///
  ///     raster (GPU)          avg 16.7  p90 22.1 ms
  ///     373 of 2635 frames over 16.7 ms
  ///
  /// against 17.3 ms at sigma 14. Worse, not better — and even allowing that
  /// other builds landed in between and the sample is not clean, a change made
  /// to buy raster time that comes back with more of it has not earned its
  /// place. Lowering it again needs a different reason than this one.
  ///
  /// So the cost is somewhere else on that device. The next two suspects, in
  /// order: the aurora's four radial-gradient shaders per paint, and the
  /// overdraw of stacked glass panes. Each gets its own build and its own
  /// measurement, the way this one did — that part worked, even though the
  /// answer was no.
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
