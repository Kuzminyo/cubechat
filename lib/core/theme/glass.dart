import 'dart:ui' show ImageFilter, TileMode;

import 'package:flutter/widgets.dart';

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
/// A pane's blur, or nothing, depending on what this phone can afford.
///
/// One widget rather than the same ternary at five call sites — and one place
/// for the next person to find when they wonder why a pane is flat. The answer
/// is [AppBlur.panes] and the reasoning is on it.
class GlassBlur extends StatelessWidget {
  const GlassBlur({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!AppBlur.panes) return child;
    // Same widget type either way, so flipping the experiment updates the
    // render object instead of remounting the pane. Outside a [BackdropGroup]
    // the grouped constructor finds no key and filters on its own.
    return AppBlur.groupedPanes
        ? BackdropFilter.grouped(filter: AppBlur.pane, child: child)
        : BackdropFilter(filter: AppBlur.pane, child: child);
  }
}

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

  /// Whether panes filter what is behind them at all.
  ///
  /// Mutable static, written once by [GlassTierController] and read at build
  /// time — the same shape `AppColors` uses for palettes, and for the same
  /// reason: it has to reach every pane in the app without threading a
  /// parameter through all of them.
  ///
  /// **Stable on purpose.** Dropping the blur *dynamically* — when the app is
  /// scrolling, when a pane is off-screen, when anything moves — has been
  /// written and reverted twice, and the report was the same words both times:
  /// the surfaces flicker between see-through and solid. See the note in
  /// `floating_glass.dart`. This flag changes on a settings tap or once at
  /// startup, so there is nothing to flicker against.
  ///
  /// Why it exists: three panes filter permanently, and each re-runs its
  /// gaussian on every frame the content behind it moves. On a phone whose GPU
  /// can afford it that is the interface. On one that cannot it was measured at
  /// `raster avg 16.0 / p90 25.0 ms`, 197 frames of 2325 over budget and 64% of
  /// a core, with the panel naming it outright: *GPU-bound — blur / gradients /
  /// overdraw*. The same build on a faster phone sat at 2.7 ms.
  ///
  /// Lowering [sigma] instead was measured and made it worse — see above. This
  /// is the other lever.
  ///
  /// **How much it is worth, measured 2026-09-04 on a 120 Hz Android phone.**
  /// Forty seconds of the same use on each setting, reading the rasterizer's
  /// CPU off the Diagnostics panel:
  ///
  /// ```
  /// full glass   GPU raster 30% of a core
  /// light glass  GPU raster 28% of a core
  /// ```
  ///
  /// Two points. On a phone whose frames were already healthy the whole blur is
  /// worth almost nothing, and what the rasterizer is actually spending its
  /// time on is everything else — the full-screen gradients, the translucent
  /// panes stacked over them, and a route transition drawing two of those
  /// stacks at once, all of it at 120 frames a second.
  ///
  /// That does not retire this flag: the phone it was written for sat at `raster
  /// avg 16.0 / p90 25.0 ms`, and a gaussian is not free there. It does retire
  /// the sentence "the blur is the expensive thing", which this setting's own
  /// hint used to say and no longer does. Anyone reaching for the next
  /// GPU-side win should start with overdraw, not with the filter.
  static bool panes = true;

  /// The conversation's islands — header, pinned bar, composer — share one
  /// read of what is behind them instead of taking three. Only inside the
  /// [BackdropGroup] the chat screen sets up; every other pane in the app,
  /// with no group above it, filters on its own exactly as before. Not a
  /// setting: `TransitionBenchmark` turns it off for its comparison rounds.
  ///
  /// How it got here. Build 1059's scripted run, twice over the same chat,
  /// frames per 300 ms slide:
  ///
  /// ```
  ///               over 8.3 ms   raster p95
  /// as it is        13-15        14-15 ms
  /// no blur          1-4          5-9 ms
  /// placeholders    12-20        15 ms
  /// ```
  ///
  /// So on that phone a chat's slide costs its islands' blur, which
  /// `chat_input.dart` keeps on through a transition on purpose (turning it
  /// off flickers, reported twice). Build 1060 ran grouped beside the other
  /// two, eight rounds each, taking turns, per chat open / close:
  ///
  /// ```
  ///               open: >8.3  >16.7  raster p95   close: >16.7  raster p95
  /// separate            14.1    1.4    15.0 ms           2.6    16.6 ms
  /// grouped              8.9    0.8    11.1 ms           0.9    13.3 ms
  /// no blur              1.1    0.4     7.2 ms           0.6    10.1 ms
  /// ```
  ///
  /// Every grouped open landed at 8-10 frames over budget against 11-15
  /// separate, so it is not noise; and the close's frames over 16.7 ms fell
  /// to where no blur puts them. What is left between grouped and no blur is
  /// the gaussian itself, which cannot go without the panes looking different.
  ///
  /// It was tried app-wide on 2026-08-06 and reverted as "less smooth
  /// everywhere" — by feel, with nothing that could put a number on one slide.
  /// See [FloatingGlass.blur], which is still not grouped.
  static bool groupedPanes = true;

  /// Ready-made filter, so no call site has to remember to pass the same value
  /// to both axes.
  ///
  /// `final`, not a getter: one instance for the whole app rather than a fresh
  /// one per build, so the layer comparison that decides whether a backdrop has
  /// to be re-filtered sees the same object each frame.
  ///
  /// `TileMode.decal` because of what `clamp` does at the edge of the layer.
  ///
  /// The default repeats the outermost row of sampled pixels outwards to feed
  /// the gaussian, so every pane painted a faint rectangle of smeared backdrop
  /// around itself — square-cornered, on a rounded island, most visible over
  /// the aurora's gradient where there is nothing to hide it. It was reported
  /// as "some shadow, a micro border behind the islands", which is exactly
  /// what it is: not a shadow (this widget's shadow list is empty) and not a
  /// border, but the blur's own edge.
  ///
  /// `decal` treats everything outside as transparent instead, so the filter
  /// has nothing to smear and the pane ends where its clip ends.
  static final ImageFilter pane = ImageFilter.blur(
    sigmaX: sigma,
    sigmaY: sigma,
    tileMode: TileMode.decal,
  );
}
