import 'dart:async';
import 'dart:ui' show FrameTiming, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../storage/hive_cipher.dart';
import '../storage/hive_init.dart';
import '../util/debug_log.dart';
import '../util/frame_stats.dart';
import '../util/ui_activity.dart';
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
  ///
  /// `.v2` since the verdict also asks about screen changes (see
  /// [_slideMarginMs]): a phone told "full" by the first question alone is
  /// asked again, once. A "light" from it stands — see [_rememberedVerdict].
  static const _autoVerdictKey = 'glass.tier.auto.v2';
  static const _firstVerdictKey = 'glass.tier.auto';

  String? _rememberedVerdict(Box<dynamic> box) {
    final now = box.get(_autoVerdictKey) as String?;
    if (now != null) return now;
    final first = box.get(_firstVerdictKey) as String?;
    return first == GlassTier.light.name ? first : null;
  }

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

  /// A single frame long enough to be felt as a stop, not a stutter.
  ///
  /// The p90 above cannot see this and that is the point. Measured on a 120 Hz
  /// Android phone on 2026-09-04: raster p90 4.5 ms, whole session 41 slow
  /// frames out of 3697 — by every rolling number, a phone that can easily
  /// afford the glass. And it froze on the way back out of a chat, repeatedly,
  /// with `build 0.5 ms, raster 93.1 ms` in the log: eleven dropped frames in a
  /// row, and the one thing the person holding it actually complained about.
  ///
  /// The cause is the blur's own optimisation. Panes drop the gaussian while a
  /// route slides (see `_holdGlassStill`) and take it back when the animation
  /// ends — so every pane's backdrop layer is allocated again in one frame. Set
  /// to light glass on the same phone, the worst raster frame went from 93 ms
  /// to 27 and the freeze went with it.
  ///
  /// So the verdict asks both questions. An average says whether the interface
  /// is affordable; the worst frame says whether it is *bearable*, and one 90 ms
  /// stop is worth more than a thousand frames that were 2 ms under budget.
  /// 50 ms is three dropped frames at 60 Hz — past arguing about.
  static const double _rasterWorstCeiling = 50;

  /// Long enough to catch scrolling and a screen change, short enough that the
  /// answer arrives while the app is still being opened for the first time.
  static const Duration _measureAfter = Duration(seconds: 45);

  /// Below this, the window was too idle to judge — a phone that drew forty
  /// frames while somebody read one screen has proved nothing either way.
  static const int _minFrames = 300;

  @override
  GlassTier build() {
    ref.onDispose(_stopSampling);
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
      final remembered = _rememberedVerdict(box);
      _apply(chosen, remembered: remembered);
      if (chosen == GlassTier.auto && remembered == null) {
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
  ///
  /// **The frames are its own.** It used to read [FrameStats], which collects
  /// only while the Diagnostics screen is open — so in ordinary use it counted
  /// nothing, took the "too few frames" branch, and rescheduled for ever. Auto
  /// glass never decided anything on any phone, and a Mali phone drawing at
  /// raster avg 25 / p90 38.7 ms (30 fps) kept the full blur (2026-10-01).
  void _scheduleMeasurement() {
    _stopSampling();
    _measure = Timer(_settleAfter, () {
      _measure = null;
      _window = RasterWindow();
      _slides = RasterWindow();
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      if (!_watchingFrames) {
        // Persistent callbacks cannot be removed; this one is a flag check
        // whenever nothing is being measured.
        _watchingFrames = true;
        SchedulerBinding.instance.addPersistentFrameCallback(_noteFrame);
      }
      _measure = Timer(_measureAfter, _judge);
    });
  }

  RasterWindow? _window;

  /// The same, for frames drawn while a screen was sliding in or out.
  RasterWindow? _slides;

  bool _watchingFrames = false;

  /// Frames built while a screen was changing, by engine frame number.
  ///
  /// Timings arrive up to a second late in a release build, by which time the
  /// slide is over, so the question "was this frame part of one" is answered
  /// as the frame is built and looked up when its timing turns up.
  final Set<int> _slideFrames = <int>{};

  void _noteFrame(Duration _) {
    if (_slides == null || !UiActivity.instance.isNavigating.value) return;
    _slideFrames.add(PlatformDispatcher.instance.frameData.frameNumber);
    if (_slideFrames.length > 2000) _slideFrames.remove(_slideFrames.first);
  }

  void _onTimings(List<FrameTiming> timings) {
    final window = _window;
    if (window == null) return;
    for (final t in timings) {
      window.add(t.rasterDuration);
      if (_slideFrames.remove(t.frameNumber)) {
        _slides?.add(t.rasterDuration);
      }
    }
  }

  void _stopSampling() {
    _measure?.cancel();
    _measure = null;
    if (_window != null) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _window = null;
      _slides = null;
      _slideFrames.clear();
    }
  }

  Future<void> _judge() async {
    _measure = null;
    final window = _window;
    final slides = _slides;
    if (window == null || slides == null) return;
    final budgetMs = _frameBudgetMs();
    final verdict = verdictFor(
      p90Ms: window.p90Ms,
      worstMs: window.worstMs,
      slideP90Ms: slides.count < _minSlideFrames ? null : slides.p90Ms,
      budgetMs: budgetMs,
    );
    // Too little happened to judge. Keep watching rather than guess — unless
    // what did happen already says light, which more frames cannot undo.
    if (window.count < _minFrames ||
        (verdict == GlassTier.full && slides.count < _minSlideFrames)) {
      _measure = Timer(_measureAfter, _judge);
      return;
    }
    _stopSampling();
    DebugLog.instance.log(
      'GLASS',
      'raster p90 ${window.p90Ms.toStringAsFixed(1)} ms, worst '
          '${window.worstMs.toStringAsFixed(1)} ms over ${window.count} '
          'frames; screen changes p90 ${slides.p90Ms.toStringAsFixed(1)} ms '
          'over ${slides.count} against a '
          '${budgetMs.toStringAsFixed(1)} ms frame — ${verdict.name} glass',
    );
    try {
      await _box?.put(_autoVerdictKey, verdict.name);
    } catch (e) {
      debugPrint('glass verdict persist failed: $e');
    }
    if (state == GlassTier.auto) {
      _apply(GlassTier.auto, remembered: verdict.name);
    }
  }

  /// The verdict on one window of use. See [_rasterP90Ceiling],
  /// [_rasterWorstCeiling] and [_slideMarginMs] for why it asks all three.
  static GlassTier verdictFor({
    required double p90Ms,
    required double worstMs,
    double? slideP90Ms,
    double budgetMs = 1000 / 60,
  }) =>
      p90Ms > _rasterP90Ceiling ||
              worstMs > _rasterWorstCeiling ||
              (slideP90Ms != null && slideP90Ms > budgetMs + _slideMarginMs)
          ? GlassTier.light
          : GlassTier.full;

  /// How far past its own refresh the slow tenth of a phone's screen-change
  /// frames may run before the glass goes.
  ///
  /// The two questions above are asked of every frame, and most frames are a
  /// screen sitting still. The glass costs most where the owner reported
  /// phones with weak graphics lagging (2026-10-15): a chat sliding in or out,
  /// two screens on the display and the islands re-running their gaussian over
  /// a moving backdrop — 8.9 frames over 8.3 ms per open with it, 1.1 without
  /// (1061's scripted run). A phone that keeps a still screen under 16.7 ms
  /// and slides at 20 passed the old verdict and stuttered on every chat.
  ///
  /// Measured against the display's own frame rather than a fixed 60 Hz, and
  /// with half a 120 Hz frame of slack: the S24+ slides at raster p95 9-11 ms
  /// on a 120 Hz screen (1163's scripted run), under its 12.5 here, and keeps
  /// the glass.
  static const double _slideMarginMs = 4.2;

  /// Frames from at least two screen changes before they count.
  static const int _minSlideFrames = 60;

  static double _frameBudgetMs() {
    final displays = PlatformDispatcher.instance.displays;
    final hz = displays.isEmpty ? 60.0 : displays.first.refreshRate;
    return 1000 / (hz < 30 ? 60 : hz);
  }

  /// Before sampling starts: the first seconds of a launch compile shaders
  /// and build every tab, and a single 100 ms frame among them would judge the
  /// phone on its boot rather than on its use.
  static const Duration _settleAfter = Duration(seconds: 10);

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
    final box = _box;
    final remembered = box == null ? null : _rememberedVerdict(box);
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

/// Raster times of one measuring window, kept by [GlassTierController] itself.
///
/// Bounded: a window that runs long because the phone sat idle keeps the most
/// recent frames, which is what the verdict should be about anyway.
class RasterWindow {
  static const int _capacity = 4000;

  final List<int> _us = <int>[];
  int _worstUs = 0;
  int _count = 0;

  void add(Duration raster) {
    final us = raster.inMicroseconds;
    _count++;
    if (us > _worstUs) _worstUs = us;
    _us.add(us);
    if (_us.length > _capacity) _us.removeAt(0);
  }

  int get count => _count;

  double get worstMs => _worstUs / 1000;

  double get p90Ms {
    if (_us.isEmpty) return 0;
    final sorted = List<int>.of(_us)..sort();
    final i = ((sorted.length - 1) * 0.9).round();
    return sorted[i] / 1000;
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
