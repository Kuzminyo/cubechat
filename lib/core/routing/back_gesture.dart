import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Drag right, anywhere on the page, to go back.
///
/// Flutter ships a version of this: [CupertinoRouteTransitionMixin] wraps every
/// page in one, and this app's routes use that mixin. It has never worked on
/// the phones people hold, and the reason is a single number — the strip that
/// listens for the drag is 20 logical pixels at the very leading edge, which on
/// a phone using gesture navigation is precisely the strip Android keeps for
/// its own back gesture. The touch never arrives. On a phone with buttons it
/// does arrive, and 20 pixels is about a third of a fingertip.
///
/// So the whole page listens, the way Telegram's does. What stops that from
/// swallowing every other horizontal gesture in the app is *when* it accepts
/// rather than *where*:
///
///  * **Leftward is not ours.** The moment the finger commits left the gesture
///    is handed back to the arena, because that is the swipe-to-reply on a
///    bubble.
///  * **Away from the edge it accepts late.** A slider, a seek bar or a
///    carousel claims a drag at the usual touch slop; this waits for
///    [_pageThreshold], by which time anything under the finger that wanted the
///    drag has already won it. Nothing competing means nothing to lose to, and
///    the page starts moving.
///  * **At the edge it accepts immediately**, because there the intent is not
///    ambiguous and waiting would only feel slow. The edge band starts after
///    whatever the system reserved (`systemGestureInsets` — Android's
///    back-sensitivity slider) so it does not fight the platform for the same
///    pixels.
///
/// The drag mechanics are Flutter's, reproduced rather than reused because the
/// pieces are private (`_CupertinoBackGestureDetector` and its controller), and
/// subtle enough to be worth copying exactly: the route's own animation
/// controller is handed to the finger, the navigator is told a user gesture is
/// in progress so the transition goes linear and follows it, and on release the
/// controller either finishes the pop or springs back — with the gesture flag
/// held until that settles, so the curve does not change mid-air.
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

  /// How far past the system's own gesture strip the *immediate* band reaches.
  ///
  /// A little under half a fingertip. Wider starts to feel like the left edge
  /// of the screen has become a button; much narrower and it is Flutter's 20
  /// pixels again.
  static const double _edgeReach = 44;

  /// How far the finger travels before a drag that started away from the edge
  /// is taken as "go back".
  ///
  /// Comfortably past the touch slop everything else accepts at, so a seek bar
  /// or a slider has already claimed the gesture by the time this would — and
  /// short enough that a deliberate swipe never feels like it is being ignored.
  static const double _pageThreshold = 44;

  /// Where the immediate band ends: after whatever the platform reserved for
  /// its own gesture, plus [_edgeReach].
  static double edgeBandFor(BuildContext context) {
    final media = MediaQuery.of(context);
    final reserved = math.max(
      media.systemGestureInsets.left,
      media.padding.left,
    );
    return reserved + _edgeReach;
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
      // From where the finger went *down*, not from where the gesture was won.
      //
      // This is what made the drag feel like it refused to finish. Away from
      // the edge the gesture is only claimed after 44 pixels, and with the
      // default behaviour those 44 are thrown away — so the page trailed the
      // finger by that much for the whole drag, and to push it past the
      // half-screen mark that decides a pop you had to drag most of the way
      // across. Counting from the touch means the page catches up on the frame
      // it starts moving and tracks the finger one-to-one after that.
      ..dragStartBehavior = DragStartBehavior.down
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
    if (!widget.enabledCallback()) return;
    final box = context.findRenderObject() as RenderBox?;
    final localX = box == null ? 0.0 : box.globalToLocal(event.position).dx;
    _recognizer.acceptEarly = localX <= EdgeBackGesture.edgeBandFor(context);
    _recognizer.addPointer(event);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        // The whole page, not a strip. Translucent, so it only ever listens:
        // taps, scrolls and everything else reach the screen underneath, and
        // the recognizer decides in the arena whether a horizontal drag was
        // meant for it.
        Positioned.fill(
          child: Listener(
            onPointerDown: _handlePointerDown,
            behavior: HitTestBehavior.translucent,
          ),
        ),
      ],
    );
  }
}

/// A horizontal drag that loses on purpose, twice over.
///
/// It covers the whole page, so it sits on top of every other horizontal
/// gesture in the app: swipe-to-reply on a bubble, the seek bar of a voice
/// note, a slider in settings. All of them are horizontal drags, all of them
/// accept in the gesture arena, and this one — being in front — would win every
/// single time. Two rules give them back:
///
///  * a drag that commits **leftward** is rejected outright (that is the reply
///    swipe, and nothing here ever wants it);
///  * away from the edge, acceptance waits for a distance well past the touch
///    slop, so anything under the finger that wanted the drag has claimed it
///    first and this one is already out of the arena.
class _RightwardDragRecognizer extends HorizontalDragGestureRecognizer {
  _RightwardDragRecognizer({super.debugOwner});

  /// Set from the pointer-down position: at the leading edge the intent is not
  /// ambiguous, so the drag is taken at the ordinary slop and the page starts
  /// moving with the finger straight away.
  bool acceptEarly = false;

  Offset? _origin;
  bool _decided = false;
  bool _gaveUp = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _origin = event.position;
    _decided = false;
    _gaveUp = false;
    super.addAllowedPointer(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    final slop = computeHitSlop(pointerDeviceKind, gestureSettings);
    return globalDistanceMoved.abs() >
        (acceptEarly ? slop : math.max(slop, EdgeBackGesture._pageThreshold));
  }

  @override
  void handleEvent(PointerEvent event) {
    if (_gaveUp) return;
    final origin = _origin;
    if (!_decided && origin != null && event is PointerMoveEvent) {
      final dx = event.position.dx - origin.dx;
      if (dx.abs() >= computeHitSlop(event.kind, gestureSettings)) {
        _decided = true;
        if (dx < 0) {
          _gaveUp = true;
          resolve(GestureDisposition.rejected);
          // Nothing after this: rejection stops the recognizer tracking the
          // pointer and resets it to `ready`, and the base class asserts on
          // being handed an event in that state. Handing it one is how the
          // swipe-to-reply tests found this the first time.
          return;
        }
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

  /// How much of the page has to be pushed aside for letting go to mean "go
  /// back".
  ///
  /// iOS wants half the screen; this asks for a third, which is the distance a
  /// thumb covers without the hand moving and what the gesture feels like it
  /// should take. Below this it springs back — and it can afford to be
  /// generous, because away from the leading edge the drag is not claimed at
  /// all until the finger has already travelled far enough to mean it.
  static const double _commitAt = 0.65;

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
      complete = controller.value > _commitAt;
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
