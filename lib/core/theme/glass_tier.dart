import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../storage/hive_cipher.dart';
import '../storage/hive_init.dart';
import '../util/debug_log.dart';
import '../util/frame_stats.dart';
import 'glass.dart';

/// How much glass this phone can afford.
///
/// One build runs on both a phone that draws the interface at `raster avg 2.7
/// ms` and one that sits at `avg 16.0 / p90 25.0`, 197 frames of 2325 over
/// budget, 64% of a core, with the app's own panel naming it: *GPU-bound —
/// blur / gradients / overdraw*. Three panes filter permanently and each
/// re-runs its gaussian on every frame the content behind it moves; that is
/// the interface on the first phone and a tax on the second.
///
/// So the phone is asked rather than assumed. Not by model or chipset — those
/// lists are wrong within a year — but by what its GPU actually did.
///
/// **Worth less than it looks on a phone that keeps up.** Measured 2026-09-04:
/// 30% of a core on `full`, 28% on `light`, forty seconds of the same use each.
/// The full argument and the numbers are on [AppBlur.panes]; the short version
/// is that this setting earns its place on the slow phone it was written for
/// and almost nothing on a fast one, so it is not the lever to reach for when
/// somebody with a healthy frame budget says the phone is warm.
enum GlassTier {
  /// Decide from a measurement, once, and remember the answer.
  auto,

  /// Panes filter what is behind them. What the app has always looked like.
  full,

  /// Panes are tinted but do not filter. Cheaper by the whole gaussian.
  light,
}

/// Chooses [GlassTier] and writes it where every pane can read it.
///
/// The decision is deliberately **stable**: made once at startup or by a tap in
/// settings, never per frame. Dropping the blur while something moves has been
/// tried and reverted twice — the panes visibly flicker between see-through and
/// solid — and the note in `floating_glass.dart` records both attempts. A tier
/// has nothing to flicker against because it does not change while you look at
/// it.
class GlassTierController extends Notifier<GlassTier> {
  static const _key = 'glass.tier';

  /// The measured verdict under [GlassTier.auto], remembered so a phone is
  /// judged once rather than re-judged every launch on whatever it happened to
  /// be doing in its first seconds.
  static const _autoVerdictKey = 'glass.tier.auto';

  Box<dynamic>? _box;
  Timer? _measure;

  /// Bumped on every change to [AppBlur.panes], so the app root can key off it
  /// and discard const-built panes. The same mechanism `ThemeController` uses.
  ///
  /// A provider rather than a plain field, and that is the whole of the bug it
  /// fixes: a field nobody watches changes nothing. The root keyed off the
  /// *chosen* tier, which is a different fact — under `auto` it never changes
  /// at all, so the startup measurement deciding "light" flipped the static and
  /// left every pane on screen still blurring until something else happened to
  /// rebuild the tree.
  void _bumpRevision() {
    ref.read(glassRevisionProvider.notifier).state++;
  }

  /// Above this, a phone is not keeping up and the glass is what it is paying
  /// for.
  ///
  /// p90 rather than the average: the average stays respectable on a phone that
  /// stutters, because most frames are cheap and the expensive ones are what
  /// anybody actually notices. 8.3 ms is one frame at 120 Hz; a p90 past twice
  /// that means the slow tenth of frames is missing even a 60 Hz budget.
  static const double _rasterP90Ceiling = 16.7;

  /// Long enough to catch scrolling and a screen change, short enough that the
  /// answer arrives while the app is still being opened for the first time.
  static const Duration _measureAfter = Duration(seconds: 45);

  /// Below this, the window was too idle to judge — a phone that drew forty
  /// frames while somebody read one screen has proved nothing either way.
  static const int _minFrames = 300;

  @override
  GlassTier build() {
    ref.onDispose(() {
      _measure?.cancel();
      _measure = null;
    });
    unawaited(_load());
    return GlassTier.auto;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final stored = box.get(_key) as String?;
      final chosen = GlassTier.values.firstWhere(
        (t) => t.name == stored,
        orElse: () => GlassTier.auto,
      );
      if (chosen != state) state = chosen;
      _apply(chosen, remembered: box.get(_autoVerdictKey) as String?);
      if (chosen == GlassTier.auto && box.get(_autoVerdictKey) == null) {
        _scheduleMeasurement();
      }
    } catch (e) {
      debugPrint('glass tier load failed: $e');
    }
  }

  /// Put the answer where the panes read it.
  void _apply(GlassTier tier, {String? remembered}) {
    final effective = switch (tier) {
      GlassTier.full => GlassTier.full,
      GlassTier.light => GlassTier.light,
      GlassTier.auto =>
        remembered == GlassTier.light.name ? GlassTier.light : GlassTier.full,
    };
    final panes = effective == GlassTier.full;
    if (AppBlur.panes == panes) return;
    AppBlur.panes = panes;
    _bumpRevision();
  }

  /// Watch one window of real use, then decide once.
  ///
  /// Deliberately not a running average that can flip the interface later: a
  /// phone that stutters while decoding a photo has not become a different
  /// phone, and an interface that changes appearance on its own is the flicker
  /// this whole design avoids.
  void _scheduleMeasurement() {
    _measure?.cancel();
    _measure = Timer(_measureAfter, () async {
      _measure = null;
      final stats = FrameStats.instance;
      if (stats.totalFrames < _minFrames) {
        // Too little happened to judge. Try again rather than guess.
        _scheduleMeasurement();
        return;
      }
      final p90 = stats.p90RasterMs;
      final verdict =
          p90 > _rasterP90Ceiling ? GlassTier.light : GlassTier.full;
      DebugLog.instance.log(
        'GLASS',
        'raster p90 ${p90.toStringAsFixed(1)} ms over ${stats.totalFrames} '
            'frames — ${verdict.name} glass',
      );
      try {
        await _box?.put(_autoVerdictKey, verdict.name);
      } catch (e) {
        debugPrint('glass verdict persist failed: $e');
      }
      if (state == GlassTier.auto) _apply(GlassTier.auto, remembered: verdict.name);
    });
  }

  /// Choose by hand. Never silently overridden afterwards — somebody who picked
  /// the full glass on a slow phone meant it.
  ///
  /// The order matters and used to be wrong. `state = tier` marks the root
  /// dirty; the rebuild happens on the next frame. Applying afterwards put a
  /// Hive write in between, so the tree was rebuilt reading the *old*
  /// [AppBlur.panes] and the new value landed a few milliseconds later with
  /// nothing left to rebuild. Choosing "light" then did nothing visible until
  /// the app was restarted — reported exactly that way, with the panel still
  /// showing the raster thread leading. Applied first, the rebuild the state
  /// change causes is already the right one.
  Future<void> set(GlassTier tier) async {
    final remembered = _box?.get(_autoVerdictKey) as String?;
    _apply(tier, remembered: remembered);
    state = tier;
    if (tier == GlassTier.auto && remembered == null) {
      _scheduleMeasurement();
    }
    try {
      await _box?.put(_key, tier.name);
    } catch (e) {
      // Persisting is the part that may fail; the interface has already
      // changed, and it changing back on the next launch is the honest result
      // of a failed write rather than a reason to ignore the tap.
      debugPrint('glass tier persist failed: $e');
    }
  }
}

final glassTierControllerProvider =
    NotifierProvider<GlassTierController, GlassTier>(GlassTierController.new);

/// Changes whenever [AppBlur.panes] does.
///
/// The app root watches this and not the chosen tier. The two are different
/// questions: the tier is what the user picked, and under `auto` it stays
/// `auto` forever while the thing that actually decides — the measurement —
/// flips underneath it.
final glassRevisionProvider = StateProvider<int>((ref) => 0);
