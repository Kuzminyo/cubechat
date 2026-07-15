import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Full-screen aurora gradient with slowly drifting blobs.
///
/// The drift animation is confined to a [CustomPaint] behind a
/// [RepaintBoundary]: [child] is a *sibling* of the painter, never a descendant
/// of the animation. (It used to sit inside the `AnimatedBuilder`, which
/// rebuilt the entire app subtree on every one of the animation's frames.)
///
/// The drift is driven by a ~30 fps wall-clock ticker rather than an
/// [AnimationController] (which repaints every vsync — 120 fps on ProMotion).
/// The blobs rebuild four radial-gradient shaders per paint, so at 120 fps the
/// backdrop kept the GPU busy even while the app sat idle; the drift is far too
/// slow (24 s period) for the difference between 30 and 120 fps to be visible.
/// The ticker also pauses whenever the app leaves the foreground, so an
/// idle-but-open app never spins the GPU on an animation nobody can see.
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
  /// Drift phase in [0, 1), advanced ~30 times/second off wall-clock time.
  final ValueNotifier<double> _drift = ValueNotifier<double>(0);
  final Stopwatch _clock = Stopwatch();
  Timer? _ticker;

  static const Duration _driftPeriod = Duration(seconds: 24);
  static const Duration _tickInterval = Duration(milliseconds: 33); // ~30 fps

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
    // Only run the ticker while we're actually on screen.
    if (WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _startTicker();
    }
  }

  void _startTicker() {
    if (_ticker != null) return;
    _clock.start();
    _ticker = Timer.periodic(_tickInterval, (_) {
      final periodMs = _driftPeriod.inMilliseconds;
      _drift.value = (_clock.elapsedMilliseconds % periodMs) / periodMs;
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
    _clock.stop(); // preserves elapsed, so the drift resumes seamlessly
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startTicker();
    } else {
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
        widget.child,
      ],
    );
  }
}

/// Paints the whole backdrop — base gradient, four drifting blobs, scrim — in
/// one pass. Repaints are driven straight off the controllers, so no widget in
/// the tree rebuilds when the aurora moves.
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

  static const _base = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.bgTop, AppColors.bgBottom],
  );

  // The base gradient depends only on size, so build its shader once per size
  // and reuse it across frames instead of rebuilding it on every paint.
  Shader? _baseShader;
  Size? _baseShaderSize;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (_baseShader == null || _baseShaderSize != size) {
      _baseShader = _base.createShader(rect);
      _baseShaderSize = size;
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
      Alignment(-0.7 + 0.25 * math.sin(t) - dx, -0.6 + 0.18 * math.cos(t * 0.8) - dy),
      AppColors.aurora1,
      0.55 + 0.05 * math.sin(t * 0.5),
      0.55,
    );
    _blob(
      canvas,
      rect,
      Alignment(0.7 + 0.20 * math.cos(t * 0.7) - dx, -0.7 + 0.22 * math.sin(t * 0.9) + dy),
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
      Alignment(0.4 + 0.30 * math.sin(t * 1.1 + 1) - dx, 0.48 + 0.18 * math.cos(t * 0.8 + 1) + dy),
      AppColors.aurora3,
      0.55 + 0.04 * math.sin(t * 0.7),
      0.46,
    );
    _blob(
      canvas,
      rect,
      Alignment(-0.6 + 0.25 * math.cos(t * 0.9 + 2) - dx, 0.52 + 0.15 * math.sin(t * 0.6 + 2) - dy),
      AppColors.aurora4,
      0.45 + 0.05 * math.cos(t * 0.85),
      0.30,
    );

    canvas.drawRect(rect, Paint()..color = Colors.black.withValues(alpha: 0.28));
  }

  void _blob(
    Canvas canvas,
    Rect rect,
    Alignment center,
    Color color,
    double radius,
    double alpha,
  ) {
    final shader = RadialGradient(
      center: center,
      radius: radius,
      colors: [color.withValues(alpha: alpha), Colors.transparent],
    ).createShader(rect);
    canvas.drawRect(rect, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _AuroraPainter old) =>
      old.focusFrom != focusFrom || old.focusTo != focusTo;
}
