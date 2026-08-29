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
  /// Past the touch slop everything else accepts at (18), so a seek bar or a
  /// slider has already claimed the gesture by the time this would — and short
  /// enough that a deliberate swipe never feels like it is being ignored. It
  /// was 44, which is most of a fingertip and read as the gesture not working
  /// away from the edge at all.
  static const double _pageThreshold = 26;

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

  /// How long a full screen's worth of travel takes once the finger is off.
  ///
  /// It used to be 350 ms flat, whatever was left to cover, and that is the
  /// whole of what made the release feel wrong in both directions. Let go an
  /// inch in and the page took 350 ms to crawl back a tenth of the way, which
  /// reads as the app thinking about it. Flick it three-quarters across and it
  /// took the same 350 ms to finish the last quarter, which throws away the
  /// speed the thumb just put into it — the hand says fast, the screen says
  /// leisurely, and the join between them is what "not smooth" means here.
  ///
  /// Proportional to the distance left, so the *pace* is constant instead of
  /// the duration.
  ///
  /// 380 rather than the push's 300. Making it proportional was right and made
  /// it too quick: a push starts from a standstill and has to announce itself,
  /// while a release is already in motion and only has to land, so the same
  /// number reads as hurried in the second case. Slower than the push, faster
  /// than the flat 350 it replaced at every distance beyond about four fifths.
  static const Duration _settleFull = Duration(milliseconds: 380);

  /// Under this, a settle stops reading as motion and starts reading as a snap.
  /// A page an inch from home does not need a tenth of a second, but going to
  /// zero makes the last moment of the gesture jump.
  static const Duration _settleMin = Duration(milliseconds: 150);

  /// A flick has already done the moving; the animation is only catching up to
  /// a decision the hand made, so it covers what is left faster.
  static const double _flingPace = 0.7;

  static Duration _settleFor(double distance, double velocity) {
    final travel = distance.clamp(0.0, 1.0);
    final pace = velocity.abs() >= _minFlingVelocity ? _flingPace : 1.0;
    final ms = (_settleFull.inMilliseconds * pace * travel).round();
    return Duration(
      milliseconds: ms < _settleMin.inMilliseconds
          ? _settleMin.inMilliseconds
          : ms,
    );
  }

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
      // Back where it came from: what is left is the gap up to 1.
      controller.animateTo(
        1,
        duration: _settleFor(1 - controller.value, velocity),
        curve: curve,
      );
    } else {
      if (current) navigator.pop();
      // Settled either way, and that "either" is the fix.
      //
      // This used to animate back only when the pop had already started one —
      // which is the ordinary case and not the only one. A `PopScope` that
      // answers the pop itself, a route something else has just taken off the
      // stack: in both, `navigator.pop()` returns having moved nothing, the
      // controller is not animating, and the page is left sitting exactly where
      // the finger let go of it. A screen stopped halfway across, reported
      // three times as the back gesture leaving a chat half-closed.
      //
      // A gesture-driven animation must never be left between its endpoints.
      // Nothing is lost by being sure: when the pop did start the reverse, this
      // only replaces its curve with the one the release was already using.
      if (isActive() || controller.isAnimating) {
        controller.animateBack(
          0,
          duration: _settleFor(controller.value, velocity),
          curve: curve,
        );
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

/// A horizontal drag that only ever means "leftward", for the swipe-to-reply on
/// a message bubble.
///
/// The mirror of [_RightwardDragRecognizer], and it exists for the same reason
/// in the opposite direction. A plain `onHorizontalDragUpdate` accepts at the
/// ordinary touch slop whichever way the finger went, so a bubble claimed every
/// rightward drag too — and then did nothing with it, because the reply offset
/// is clamped to zero on that side. The visible result was the back gesture
/// working everywhere except over the conversation, which is most of the screen
/// and the place people most want to swipe out of.
///
/// Rejecting the direction it cannot use hands those drags back to the arena,
/// where the page's own recognizer is waiting.
class LeftwardDragRecognizer extends _OneWayDragRecognizer {
  LeftwardDragRecognizer({super.debugOwner}) : super(wantedSign: -1);
}

/// The same thing pointing the other way, for the swipe action on a chat row.
///
/// A row lives inside the strip of tab branches, whose own horizontal drag
/// covers the whole screen. Claiming only the direction the action uses is what
/// lets the two share the gesture: swiping right on a chat opens its action,
/// swiping left still walks to the next tab. Nothing had to be taken away from
/// the strip to add the row's gesture.
class RightwardDragRecognizer extends _OneWayDragRecognizer {
  RightwardDragRecognizer({super.debugOwner}) : super(wantedSign: 1);
}

/// A horizontal drag that gives up the direction it cannot use.
///
/// A plain `onHorizontalDragUpdate` accepts at the ordinary touch slop whichever
/// way the finger went, so a widget that only means one direction claimed the
/// other too — and then did nothing with it, because its offset is clamped on
/// that side. The visible result was the back gesture working everywhere except
/// over a conversation, which is most of the screen and the place people most
/// want to swipe out of.
///
/// Rejecting the wrong direction hands those drags back to the arena, where
/// whatever else wanted them is waiting.
abstract class _OneWayDragRecognizer extends HorizontalDragGestureRecognizer {
  _OneWayDragRecognizer({super.debugOwner, required this.wantedSign});

  /// 1 for rightward, -1 for leftward.
  final int wantedSign;

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
  void handleEvent(PointerEvent event) {
    if (_gaveUp) return;
    final origin = _origin;
    if (!_decided && origin != null && event is PointerMoveEvent) {
      final dx = event.position.dx - origin.dx;
      if (dx.abs() >= computeHitSlop(event.kind, gestureSettings)) {
        _decided = true;
        if (dx.sign != wantedSign) {
          _gaveUp = true;
          resolve(GestureDisposition.rejected);
          // Nothing after this — see the note in [_RightwardDragRecognizer],
          // which learned it the hard way: a rejected recognizer is reset to
          // `ready` and the base class asserts on being handed another event.
          return;
        }
      }
    }
    super.handleEvent(event);
  }
}

/// A vertical drag that takes itself off the list underneath.
///
/// A scroll view claims vertical drags, so an ordinary detector on something
/// inside one never sees them: both recognizers wait for the same slop and the
/// scrollable's is the one the arena hands it to. This accepts after two points
/// of travel and therefore wins.
///
/// Used by the profile headers, where the gesture is about the picture rather
/// than about the list: swiping up the face opens it. Deliberately small,
/// because it only ever covers the picture and the alternative is a gesture
/// that does not exist at all.
class EagerVerticalDragRecognizer extends VerticalDragGestureRecognizer {
  EagerVerticalDragRecognizer({super.debugOwner});

  Offset? _origin;
  bool _claimed = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _origin = event.position;
    _claimed = false;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    final origin = _origin;
    if (!_claimed && origin != null && event is PointerMoveEvent) {
      if ((event.position.dy - origin.dy).abs() >= 2) {
        _claimed = true;
        resolve(GestureDisposition.accepted);
      }
    }
    super.handleEvent(event);
  }
}
