import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../theme/colors.dart';
import '../util/ui_activity.dart';

/// Full-screen aurora gradient with slowly drifting blobs.
///
/// The drift animation is confined to a [CustomPaint] behind a
/// [RepaintBoundary]: [child] is a *sibling* of the painter, never a descendant
/// of the animation. (It used to sit inside the `AnimatedBuilder`, which
/// rebuilt the entire app subtree on every one of the animation's frames.)
///
/// The drift repaints ~30 times a second rather than every vsync, which is what
/// an [AnimationController] would do (120 fps on ProMotion).
/// The blobs rebuild four radial-gradient shaders per paint, so at 120 fps the
/// backdrop kept the GPU busy even while the app sat idle; the drift is far too
/// slow (24 s period) for the difference between 30 and 120 fps to be visible.
///
/// The ticker only runs when someone is actually looking at movement: it stops
/// when the app leaves the foreground, and again [_idleAfter] a touch ends.
/// A paint used to be six full-screen draws (base + four blobs + scrim), so a
/// drift that never stopped meant the GPU never idled for as long as the app
/// was open — the single biggest reason the phone ran hot. Freezing is
/// invisible at a 24 s period, and the [Stopwatch] preserves elapsed time so
/// motion resumes from exactly where it stopped rather than jumping.
///
/// It is now one full-screen draw and four partial ones: each blob covers the
/// circle its gradient actually reaches rather than the whole screen, and the
/// scrim is folded into the colours ([_shade]) instead of being a sixth pass.
/// Both were pixel-identical rewrites — the design-QA goldens passed unchanged
/// across them — and together they halved p90 raster time on a 120 Hz device,
/// from 11.4 ms to 5.8.
///
/// Tab changes animate through [_focus], which repaints the painter on its own
/// — so the backdrop still reacts to navigation while the drift is parked.
///
/// [focus] lets the background react to navigation: pass the active tab index
/// and the blobs ease sideways, so each tab has its own light. Routes outside
/// the tab shell leave it at the neutral middle.
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, required this.child, this.focus = 1.0});

  final Widget child;

  /// Active tab index (0..2). 1.0 is neutral — no shift.
  final double focus;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  /// Drift phase in [0, 1), advanced ~30 times/second.
  final ValueNotifier<double> _drift = ValueNotifier<double>(0);
  final Stopwatch _clock = Stopwatch();

  /// Pumped by vsync, throttled to [_tickInterval] — see [_startTicker].
  Ticker? _ticker;

  /// Wall-clock reading at the last repaint, so the throttle can tell whether
  /// this vsync is the one that owes a new frame.
  int _lastPaintMs = 0;

  static const Duration _driftPeriod = Duration(seconds: 24);
  static const Duration _tickInterval = Duration(milliseconds: 33); // ~30 fps

  /// How long the drift keeps running after the last touch lifts. Long enough
  /// that it stays alive between the taps of a browsing session, short enough
  /// that a put-down phone stops repainting almost immediately.
  static const Duration _idleAfter = Duration(seconds: 2);

  Timer? _idleTimer;

  /// Pointers currently down. The drift never idles mid-gesture — a slow drag
  /// would otherwise freeze the backdrop under the user's own finger.
  int _pointers = 0;

  /// Pauses decorative work for both the drag and its inertial coast.
  bool _scrolling = false;

  /// Drives the ease between the previous and the current [widget.focus].
  /// Starts completed so the first frame paints at the requested focus.
  late final AnimationController _focus = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
    value: 1,
  );

  late double _focusFrom = widget.focus;
  late double _focusTo = widget.focus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    UiActivity.instance.isNavigating.addListener(_onNavigation);
    // Only run the ticker while we're actually on screen. Drift on launch, then
    // settle: the first frames are the ones with motion worth seeing.
    if (WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      // Not immediately. A launch spends its first seconds opening and
      // decrypting Hive, restoring keys, standing up BLE and connecting
      // relays that immediately start publishing — measured at 63% of a core
      // against the 15% the same app settles to. Animating the most expensive
      // surface in the app straight into that is what a cold start being
      // rough, and only a cold start, looks like.
      //
      // The drift is invisible for its first second anyway: a 24 s period
      // moves the blobs a fifteenth of the way across in that time. What is
      // lost is nothing; what is freed is the GPU, during the only window that
      // has ever been reported as bad.
      _launchDelay = Timer(_quietAtLaunch, () {
        _launchDelay = null;
        if (mounted) _wake();
      });
    }
  }

  /// How long after launch the backdrop stays still — see [initState].
  static const Duration _quietAtLaunch = Duration(milliseconds: 2500);

  Timer? _launchDelay;

  /// Run the drift now, and park it once things go quiet again.
  void _wake() {
    _startTicker();
    _scheduleIdle();
  }

  void _scheduleIdle() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_pointers > 0 || _scrolling) return;
    _idleTimer = Timer(_idleAfter, _stopTicker);
  }

  /// Advance the drift, on vsync, about thirty times a second.
  ///
  /// The rate is the one the previous round measured and is unchanged; the
  /// clock it keeps is not. A `Timer.periodic(33ms)` fires on wall time, which
  /// has no relationship to when the display is ready for a frame: on a 90 Hz
  /// panel a vsync comes every 11.1 ms, so a 33 ms timer lands 2 or 3 vsyncs
  /// apart in a drifting pattern, and a repaint requested just after a vsync
  /// waits for the next one. Nothing is *dropped* — every frame arrives — but
  /// the interval between them keeps changing, and uneven pacing is read as
  /// stutter by the eye just as surely as a missed frame. The same point is
  /// made about refresh rate in `_matchDisplayRefreshRate`.
  ///
  /// A [Ticker] fires *on* vsync, so the throttle below picks whole vsyncs:
  /// every 3rd at 90 Hz, every 4th at 120, every 2nd at 60 — a steady interval
  /// at each, and still about thirty repaints a second. That keeps the cost
  /// this class was rewritten for (four radial-gradient shaders per paint, the
  /// reason an every-vsync [AnimationController] was rejected) while removing
  /// the jitter.
  ///
  /// This matters most when nothing else is painting: the drift runs on launch
  /// and for [_idleAfter] after each touch, and is stopped outright while
  /// scrolling — which is exactly the "janky until you scroll, smooth once you
  /// do" the report described.
  ///
  /// Measured on the reporter's 120 Hz Android after the change: raster p90
  /// 3.4 ms (avg 2.9) against 5.9 ms on 0.50.4, build p90 1.5 ms (avg 0.6),
  /// and 31 frames over 16.7 ms out of 4677 for the whole session — no stalls.
  /// The reported stutter went with it. Note what did *not* change: repaints
  /// are still ~30 a second and each still builds its four shaders, so this
  /// bought pacing, not work. GPU raster remains the busiest thread at 8% of a
  /// core against the UI thread's 5%, which is what this backdrop costs and is
  /// the number to beat if it is ever worth beating.
  ///
  /// The cold start was then measured on its own, since that is the half of
  /// the report this was meant to answer: 0 of 228 frames over 16.7 ms, worst
  /// frame 16 ms build. Launch costs 63% of a core for its first two seconds —
  /// Hive opening and decrypting, keys, BLE, relays connecting and already
  /// publishing — which is finite startup work, not a standing cost; the same
  /// app settles to 15%.
  ///
  /// That also disposes of a guess written here first time round: the 36 ms
  /// build frame in the reading above is *not* a cold start, because a cold
  /// start's worst is 16 ms. It happened somewhere in a 4677-frame session and
  /// has no explanation yet. One frame in 4677 has not earned an investigation,
  /// but it should not be filed under a cause it does not have either.
  void _startTicker() {
    if (_ticker != null) return;
    _clock.start();
    _lastPaintMs = _clock.elapsedMilliseconds;
    _ticker = createTicker((_) {
      final now = _clock.elapsedMilliseconds;
      if (now - _lastPaintMs < _tickInterval.inMilliseconds) return;
      _lastPaintMs = now;
      final periodMs = _driftPeriod.inMilliseconds;
      _drift.value = (now % periodMs) / periodMs;
    })
      ..start();
  }

  void _stopTicker() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _ticker?.dispose();
    _ticker = null;
    _clock.stop(); // preserves elapsed, so the drift resumes seamlessly
  }

  /// Park the drift while a route is sliding, for the reason it parks while a
  /// list is scrolling: the backdrop is already moving, nobody is looking at
  /// the blobs, and a transition is the most expensive moment in the app —
  /// two screens' worth of panes over this gradient at once. Measured at 37 to
  /// 47 ms of raster per frame before the panes stopped filtering during one.
  ///
  /// Registered as a listener rather than read in `build`, because the drift
  /// runs on a ticker outside the build cycle and this has to reach the ticker.
  void _onNavigation() {
    if (UiActivity.instance.isNavigating.value) {
      _stopTicker();
    } else if (_pointers == 0 && !_scrolling) {
      _wake();
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification && !_scrolling) {
      _scrolling = true;
      UiActivity.instance.setScrolling(true);
      _stopTicker();
    } else if (notification is ScrollEndNotification && _scrolling) {
      _scrolling = false;
      UiActivity.instance.setScrolling(false);
      if (_pointers == 0) _wake();
    }
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _wake();
    } else {
      _pointers = 0; // no gesture survives backgrounding
      _scrolling = false;
      UiActivity.instance.setScrolling(false);
      _stopTicker();
    }
  }

  @override
  void didUpdateWidget(covariant AuroraBackground old) {
    super.didUpdateWidget(old);
    if (widget.focus != old.focus) {
      // Retarget from wherever the ease currently sits, so a fast tab tap
      // mid-flight doesn't snap.
      _focusFrom = _currentFocus;
      _focusTo = widget.focus;
      _focus.forward(from: 0);
      _wake(); // a tab change is worth some motion behind it
    }
  }

  double get _currentFocus => lerpDouble(
        _focusFrom,
        _focusTo,
        Curves.easeOutCubic.transform(_focus.value),
      )!;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _launchDelay?.cancel();
    UiActivity.instance.isNavigating.removeListener(_onNavigation);
    UiActivity.instance.setScrolling(false);
    _stopTicker();
    _drift.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            painter: _AuroraPainter(
              drift: _drift,
              focus: _focus,
              focusFrom: _focusFrom,
              focusTo: _focusTo,
            ),
          ),
        ),
        // Translucent so the app still gets every event — this only observes
        // when a gesture starts and ends, to decide whether the drift is worth
        // painting. Counting pointers (rather than kicking a timer on every
        // move) keeps a scroll from churning a Timer per frame.
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) {
              _pointers++;
              // A moving background plus a moving list forces every glass
              // surface to be recomposited. Park decoration under the finger.
              _stopTicker();
            },
            onPointerUp: (_) {
              if (_pointers > 0) _pointers--;
              if (!_scrolling) _wake();
            },
            onPointerCancel: (_) {
              if (_pointers > 0) _pointers--;
              if (!_scrolling) _wake();
            },
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

/// Paints the whole backdrop — base gradient and four drifting blobs, each
/// pre-dimmed by [_shade] so no separate scrim is needed — in one pass.
/// Repaints are driven straight off the controllers, so no widget in the tree
/// rebuilds when the aurora moves.
class _AuroraPainter extends CustomPainter {
  _AuroraPainter({
    required this.drift,
    required this.focus,
    required this.focusFrom,
    required this.focusTo,
  }) : super(repaint: Listenable.merge([drift, focus]));

  final ValueListenable<double> drift;
  final Animation<double> focus;
  final double focusFrom;
  final double focusTo;

  /// The palette this painter was built under.
  ///
  /// Captured at construction, because comparing `AppColors` against itself in
  /// [shouldRepaint] would compare a global to the same global and always find
  /// them equal. Without it a palette change repainted nothing at all while the
  /// aurora was idle — and it idles deliberately, to keep the radio and the GPU
  /// quiet — so the old backdrop simply stayed on screen until something else
  /// forced a frame. That is the other half of "you have to restart the app".
  final int paletteStamp = Object.hash(
    AppColors.bgTop,
    AppColors.bgBottom,
    AppColors.aurora1,
    AppColors.aurora2,
    AppColors.aurora3,
    AppColors.aurora4,
  );

  // Read at paint time, not held in a `static final`.
  //
  // It used to be static, built once at first use — which meant the whole
  // backdrop kept the palette that happened to be active when the first
  // aurora was painted. Switching from emerald to indigo recoloured the blobs
  // (they read AppColors at paint) and left the gradient underneath them
  // green until the app was restarted, which is exactly the half-changed
  // theme people reported.
  static LinearGradient get _base => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [_dim(AppColors.bgTop), _dim(AppColors.bgBottom)],
      );

  /// How much of each colour survives the darkening this backdrop wants.
  ///
  /// It used to be applied as a final `drawRect` of black at 28% over the whole
  /// screen, once per repaint. Source-over with black is exactly a multiply:
  /// `0.28·0 + (1−0.28)·dst` is `0.72·dst`, and because the same factor
  /// distributes through every `over` underneath it —
  /// `a·0.72·src + (1−a)·0.72·dst == 0.72·(a·src + (1−a)·dst)` — pre-dimming
  /// the colours is not an approximation of that pass, it is the same arithmetic
  /// done once at build instead of over two and a half million pixels at 30 Hz.
  ///
  /// A full-screen blend is cheap in instructions and expensive in bandwidth,
  /// which is the thing a phone GPU actually runs out of: read, blend and write
  /// a screenful is ~20 MB of traffic, and it was happening thirty times a
  /// second to darken something that could simply have been darker.
  ///
  /// The goldens are the proof it is identical; they pass unchanged.
  static const double _shade = 0.72;

  static Color _dim(Color c) => Color.from(
        alpha: c.a,
        red: c.r * _shade,
        green: c.g * _shade,
        blue: c.b * _shade,
      );

  // The base gradient depends on size *and* on the palette, so the cached
  // shader is keyed on both — otherwise the cache would reintroduce the very
  // staleness the getter above removes.
  Shader? _baseShader;
  Size? _baseShaderSize;
  int? _baseShaderPalette;

  /// One cached shader per blob, in the order they are painted — see [_blob].
  final List<_CachedBlob?> _blobs = List<_CachedBlob?>.filled(4, null);

  /// The blob palette for the paint currently running.
  ///
  /// A field rather than a seventh argument to [_blob]: it is set at the top of
  /// [paint] and read a few lines later in the same synchronous call, and the
  /// alternative was threading one more value through four call sites that are
  /// already dense with numbers. Read at paint time for the same reason the
  /// base gradient is — a palette switch has to invalidate the cache even
  /// though the painter instance outlives it.
  int _blobPalette = 0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paletteStamp = Object.hash(AppColors.bgTop, AppColors.bgBottom);
    _blobPalette = Object.hash(
      AppColors.aurora1,
      AppColors.aurora2,
      AppColors.aurora3,
      AppColors.aurora4,
    );
    if (_baseShader == null ||
        _baseShaderSize != size ||
        _baseShaderPalette != paletteStamp) {
      _baseShader = _base.createShader(rect);
      _baseShaderSize = size;
      _baseShaderPalette = paletteStamp;
    }
    canvas.drawRect(rect, Paint()..shader = _baseShader!);

    final t = drift.value * 2 * math.pi;
    final f = lerpDouble(
      focusFrom,
      focusTo,
      Curves.easeOutCubic.transform(focus.value),
    )!;
    // Neutral at the middle tab; leans left/right for the outer ones.
    final dx = (f - 1) * 0.18;
    final dy = (f - 1) * 0.06;

    _blob(
      canvas,
      rect,
      0,
      Alignment(
          -0.7 + 0.25 * math.sin(t) - dx, -0.6 + 0.18 * math.cos(t * 0.8) - dy),
      AppColors.aurora1,
      0.55 + 0.05 * math.sin(t * 0.5),
      0.55,
    );
    _blob(
      canvas,
      rect,
      1,
      Alignment(0.7 + 0.20 * math.cos(t * 0.7) - dx,
          -0.7 + 0.22 * math.sin(t * 0.9) + dy),
      AppColors.aurora2,
      0.50 + 0.05 * math.cos(t * 0.6),
      0.55,
    );
    // The lower two are held clear of the bottom edge, and the lime one is the
    // loudest so it's dimmed hardest. Parked where they used to sit, their soft
    // rims framed the floating nav bar and read as a green plate behind it.
    _blob(
      canvas,
      rect,
      2,
      Alignment(0.4 + 0.30 * math.sin(t * 1.1 + 1) - dx,
          0.48 + 0.18 * math.cos(t * 0.8 + 1) + dy),
      AppColors.aurora3,
      0.55 + 0.04 * math.sin(t * 0.7),
      0.46,
    );
    _blob(
      canvas,
      rect,
      3,
      Alignment(-0.6 + 0.25 * math.cos(t * 0.9 + 2) - dx,
          0.52 + 0.15 * math.sin(t * 0.6 + 2) - dy),
      AppColors.aurora4,
      0.45 + 0.05 * math.cos(t * 0.85),
      0.30,
    );
  }

  /// One drifting blob, shaded only where it can actually be seen.
  ///
  /// The gradient runs from the colour at the centre to fully transparent at
  /// [radius], and `TileMode.clamp` holds it transparent past that — so every
  /// pixel outside the blob's own circle is a guaranteed no-op. It was being
  /// covered anyway: each of the four blobs did `drawRect(rect, …)` across the
  /// whole screen, so a repaint shaded every pixel of the display four times
  /// over, three of those four almost entirely for nothing.
  ///
  /// That is what the frame meter was pointing at. Halving the pane blur took
  /// the *average* raster time down (6.3 → 4.8 ms) and left p90 where it was
  /// (11.7 → 11.4), which is the signature of a cost that is not paid on every
  /// frame: the blur is, and the aurora is not — it repaints on its own ~30 Hz
  /// tick, so its cost lands on a minority of frames and shows up in the tail
  /// rather than the mean.
  ///
  /// The shader still maps against the full [rect], so the gradient's geometry
  /// is untouched; only the area handed to the rasteriser shrinks. The result
  /// is pixel-identical, and the animation — period, path, colours — is
  /// completely unchanged.
  ///
  /// A new shader used to be built here on every paint, four of them thirty
  /// times a second, and that was the biggest thing this backdrop cost.
  /// **Do not fix it by building the gradient once in unit space and scaling
  /// the canvas up to size.** Tried on 2026-08-25 and reverted within the
  /// hour: the backdrop came out in visible rectangular blocks. The arithmetic
  /// is right — a gradient is evaluated per pixel after the transform — but
  /// the engine does not evaluate it per pixel from an arbitrarily small
  /// source, and magnifying a two-unit gradient across a phone screen
  /// magnifies its own rasterisation with it.
  ///
  /// What is done instead is the second of the three ways out that failure
  /// left open: quantise the drift so one shader serves a range of positions.
  /// The space the gradient is defined in is untouched — it is still built
  /// against the full [rect], which is the part that broke last time.
  ///
  /// The step sizes come from how fast this thing actually moves. The drift
  /// period is 24 s and the tick is 33 ms, so one tick advances the phase by
  /// 0.0086 rad; the fastest blob's centre travels 0.0029 alignment units in
  /// that time, and an alignment unit is half the screen. On a 400 pt wide
  /// phone that is 0.6 pt per tick — the blobs move less than a point between
  /// repaints. Rounding to [_centreStep] means the same shader serves several
  /// ticks in a row instead of being rebuilt for a sub-pixel difference.
  ///
  /// The quantised centre is used for the rectangle as well as for the shader,
  /// not just for the cache key. They have to agree: a gradient built for one
  /// place and clipped to a circle around another clips a sliver off its own
  /// falloff, which is a real artefact rather than a rounding one.
  ///
  /// What this costs visually is a step of about 2 pt every few ticks, on a
  /// shape whose radius is ~200 pt and whose edge is a smooth alpha ramp —
  /// roughly a 1% change in alpha at the steepest point of the falloff.
  ///
  /// MEASURED, AND IT WORKED. The Mali phone, 2026-08-25, the same screen the
  /// blur experiment was rejected on:
  ///
  ///     raster (GPU)   avg 7.7  p90 16.7 ms   before
  ///     raster (GPU)   avg 7.0  p90 12.0 ms   after
  ///
  /// The p90 is the number that matters and the number nothing had moved. It
  /// sat at 17.3 with the blur at 14, went to 22.1 with the blur at 9, and was
  /// still 16.7 after every UI-thread win of the last two rounds. This is the
  /// first change to take it down, which is what the reasoning predicted: a
  /// cost paid on a minority of frames lives in the tail, and the aurora is
  /// the thing that repaints on its own clock.
  ///
  /// Whole-process CPU came down with it, 92% of a core to 70%, and the raster
  /// thread specifically from 256 to 188 ms of CPU per second of wall time.
  ///
  /// Honest caveats, because the sessions were not identical. The share of
  /// frames over 16.7 ms barely moved (20.9% to 21.7%) — the tail got shorter
  /// without the count shrinking — and build p90 read 4.7 ms against 1.7 in
  /// the earlier sample, on a session whose log was full of relay publishing.
  /// That is platform work on the merged UI thread rather than widget work,
  /// but it is a candidate explanation and not a measured one.
  void _blob(
    Canvas canvas,
    Rect rect,
    int slot,
    Alignment center,
    Color color,
    double radius,
    double alpha,
  ) {
    // Rounded to whole steps and kept as ints, so the cache comparison is
    // exact rather than a float equality that is right most of the time.
    final kx = (center.x / _centreStep).round();
    final ky = (center.y / _centreStep).round();
    final kr = (radius / _radiusStep).round();
    final at = Alignment(kx * _centreStep, ky * _centreStep);
    final r = kr * _radiusStep;

    final cached = _blobs[slot];
    final Shader shader;
    if (cached != null &&
        cached.size == rect.size &&
        cached.palette == _blobPalette &&
        cached.cx == kx &&
        cached.cy == ky &&
        cached.radius == kr) {
      shader = cached.shader;
    } else {
      shader = RadialGradient(
        center: at,
        radius: r,
        // Pre-dimmed for the same reason the base gradient is — see [_shade].
        colors: [_dim(color).withValues(alpha: alpha), Colors.transparent],
      ).createShader(rect);
      _blobs[slot] = _CachedBlob(
        shader: shader,
        size: rect.size,
        palette: _blobPalette,
        cx: kx,
        cy: ky,
        radius: kr,
      );
    }

    // `radius` is a fraction of the shortest side, which is how RadialGradient
    // reads it when it builds the shader above — so the same arithmetic here
    // gives exactly the circle the gradient dies at.
    final bounds = Rect.fromCircle(
      center: at.withinRect(rect),
      radius: r * rect.shortestSide,
    ).intersect(rect);
    // A blob can drift far enough for its circle to miss the screen entirely.
    if (bounds.isEmpty) return;
    canvas.drawRect(bounds, Paint()..shader = shader);
  }

  /// Alignment units. Half the screen is 1, so this is well under a point on a
  /// 400 pt phone.
  ///
  /// It was 0.01 — about 2 pt — chosen because the arithmetic said a 2 pt step
  /// on a 200 pt blob with a soft edge could not be seen. It was reported as
  /// visible jerking anyway, and this file has a standing record of arithmetic
  /// about it being wrong: the unit-space gradient was right on paper and came
  /// out in rectangular blocks.
  ///
  /// So the step is smaller than the per-tick movement is large. The drift
  /// advances 0.0029 units in the worst case, so at 0.004 the same shader
  /// still serves a tick or two in a row — less of the saving, none of the
  /// risk. If the jerk survives this, the aurora is not what is causing it.
  static const double _centreStep = 0.004;

  /// A blob's radius swings by ±0.05 over the whole 24 s period, so this is a
  /// far coarser grid than the centre's in proportion to what it quantises —
  /// which is the point: growth is even slower than drift.
  static const double _radiusStep = 0.004;

  @override
  bool shouldRepaint(covariant _AuroraPainter old) =>
      old.focusFrom != focusFrom ||
      old.focusTo != focusTo ||
      old.paletteStamp != paletteStamp;
}

/// One blob's shader and the quantised state it was built for — see [_blob].
///
/// Size and palette are in the key for the same reason they are in the base
/// gradient's: a rotation or a theme switch has to throw the shader away, and a
/// cache that outlives what it was built from is worse than no cache.
class _CachedBlob {
  const _CachedBlob({
    required this.shader,
    required this.size,
    required this.palette,
    required this.cx,
    required this.cy,
    required this.radius,
  });

  final Shader shader;
  final Size size;
  final int palette;
  final int cx;
  final int cy;
  final int radius;
}
