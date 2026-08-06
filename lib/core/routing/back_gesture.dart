import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A drag-back-from-the-edge gesture wide enough to actually use on Android.
///
/// Flutter already ships this: [CupertinoRouteTransitionMixin] wraps every page
/// in one, and this app's routes use that mixin. It has never worked on the
/// phones people hold, and the reason is a single number — the strip that
/// listens for the drag is 20 logical pixels at the very leading edge, and on a
/// phone using gesture navigation those same 20 pixels are the system's own
/// back gesture. Android takes the touch and the app never sees it. On a phone
/// with three buttons the strip does get the touch, and 20 pixels is about a
/// third of a fingertip.
///
/// So the strip starts *after* whatever the system has reserved
/// (`systemGestureInsets`, which is the back-sensitivity slider in Android's
/// settings) and runs [_reach] further in. What the system wants, the system
/// keeps; what is left is a band wide enough to hit without aiming.
///
/// The drag itself is Flutter's, reproduced rather than reused because the
/// pieces are private (`_CupertinoBackGestureDetector` and its controller). The
/// mechanics are subtle enough to be worth copying exactly: the route's own
/// animation controller is handed to the finger, the navigator is told a user
/// gesture is in progress so the transition goes linear and follows it, and on
/// release the controller either finishes the pop or springs back — with the
/// gesture flag held until that settles, so the curve does not change mid-air.
///
/// One thing here is deliberately *not* Flutter's: the gesture is refused as
/// soon as the finger has committed leftward. A wide strip overlaps the
/// conversation, where a leftward drag on a bubble means reply — and a back
/// gesture that ate that would be a worse trade than the one it fixed.
class EdgeBackGesture extends StatefulWidget {
  const EdgeBackGesture({
    super.key,
    required this.enabledCallback,
    required this.onStartGesture,
    required this.child,
  });

  final Widget child;

  /// Whether a drag may start at all — the route's own `popGestureEnabled`,
  /// which says no while a transition is running, on the first route, and when
  /// something has taken over popping.
  final ValueGetter<bool> enabledCallback;

  final ValueGetter<EdgeBackGestureController> onStartGesture;

  /// How far past the system's own gesture strip this one reaches.
  ///
  /// A little under half a fingertip. Wider starts to feel like the left edge
  /// of the screen has become a button; much narrower and it is Flutter's 20
  /// pixels again.
  static const double _reach = 44;

  static double widthFor(BuildContext context) {
    final media = MediaQuery.of(context);
    final reserved = math.max(
      media.systemGestureInsets.left,
      media.padding.left,
    );
    return reserved + _reach;
  }

  @override
  State<EdgeBackGesture> createState() => _EdgeBackGestureState();
}

class _EdgeBackGestureState extends State<EdgeBackGesture> {
  EdgeBackGestureController? _controller;
  late final _RightwardDragRecognizer _recognizer;

  @override
  void initState() {
    super.initState();
    _recognizer = _RightwardDragRecognizer(debugOwner: this)
      ..onStart = _handleDragStart
      ..onUpdate = _handleDragUpdate
      ..onEnd = _handleDragEnd
      ..onCancel = _handleDragCancel;
  }

  @override
  void dispose() {
    _recognizer.dispose();
    // Disposed mid-drag — the navigator is still holding a user gesture that
    // now has nobody driving it.
    final inFlight = _controller;
    if (inFlight != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (inFlight.navigator.mounted) inFlight.navigator.didStopUserGesture();
      });
      _controller = null;
    }
    super.dispose();
  }

  void _handleDragStart(DragStartDetails details) {
    _controller = widget.onStartGesture();
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final width = context.size?.width ?? 1;
    _controller?.dragUpdate(details.primaryDelta! / width);
  }

  void _handleDragEnd(DragEndDetails details) {
    final width = context.size?.width ?? 1;
    _controller?.dragEnd(details.velocity.pixelsPerSecond.dx / width);
    _controller = null;
  }

  void _handleDragCancel() {
    _controller?.dragEnd(0);
    _controller = null;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (widget.enabledCallback()) _recognizer.addPointer(event);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        PositionedDirectional(
          start: 0,
          top: 0,
          bottom: 0,
          width: EdgeBackGesture.widthFor(context),
          // Translucent: the strip listens for a drag and lets everything else
          // — taps most of all — go through to the screen underneath.
          child: Listener(
            onPointerDown: _handlePointerDown,
            behavior: HitTestBehavior.translucent,
          ),
        ),
      ],
    );
  }
}

/// A horizontal drag that gives up the moment the finger commits leftward.
///
/// The strip is wide enough to sit over chat bubbles, and a leftward drag there
/// is the swipe-to-reply. Both are horizontal drags, so both accept in the
/// gesture arena — and this one, being in front, would win every time. Losing
/// on purpose is what lets the two coexist: rightward is a back gesture,
/// leftward was never meant for us.
class _RightwardDragRecognizer extends HorizontalDragGestureRecognizer {
  _RightwardDragRecognizer({super.debugOwner});

  Offset? _origin;
  bool _decided = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _origin = event.position;
    _decided = false;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    final origin = _origin;
    if (!_decided && origin != null && event is PointerMoveEvent) {
      final dx = event.position.dx - origin.dx;
      if (dx.abs() >= computeHitSlop(event.kind, gestureSettings)) {
        _decided = true;
        if (dx < 0) resolve(GestureDisposition.rejected);
      }
    }
    super.handleEvent(event);
  }
}

/// Drives one route's transition from a finger.
///
/// Reproduces `_CupertinoBackGestureController`, which is private. Working in
/// the route's own animation coordinates: 1.0 is the page fully on screen, 0.0
/// is it gone.
class EdgeBackGestureController {
  EdgeBackGestureController({
    required this.navigator,
    required this.controller,
    required this.isCurrent,
    required this.isActive,
  }) {
    navigator.didStartUserGesture();
  }

  final NavigatorState navigator;
  final AnimationController controller;
  final ValueGetter<bool> isCurrent;
  final ValueGetter<bool> isActive;

  /// How fast a flick has to be, as a fraction of screen width per second, to
  /// decide the pop regardless of how far the drag actually got.
  static const double _minFlingVelocity = 1.0;

  static const Duration _settle = Duration(milliseconds: 350);

  void dragUpdate(double delta) => controller.value -= delta;

  void dragEnd(double velocity) {
    const curve = Curves.fastEaseInToSlowEaseOut;
    final current = isCurrent();
    final bool complete;
    if (!current) {
      // Something popped this route out from under the drag; where it goes is
      // no longer the finger's decision.
      complete = isActive();
    } else if (velocity.abs() >= _minFlingVelocity) {
      complete = velocity <= 0;
    } else {
      complete = controller.value > 0.5;
    }

    if (complete) {
      controller.animateTo(1, duration: _settle, curve: curve);
    } else {
      if (current) navigator.pop();
      if (controller.isAnimating) {
        controller.animateBack(0, duration: _settle, curve: curve);
      }
    }

    if (controller.isAnimating) {
      // Held until the animation settles: the page transition reads this flag
      // to stay linear, and dropping it early would swap curves mid-flight.
      late AnimationStatusListener onSettled;
      onSettled = (_) {
        navigator.didStopUserGesture();
        controller.removeStatusListener(onSettled);
      };
      controller.addStatusListener(onSettled);
    } else {
      navigator.didStopUserGesture();
    }
  }
}
