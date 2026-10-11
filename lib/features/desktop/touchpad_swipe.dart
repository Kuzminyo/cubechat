import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

enum SwipeDirection { back, forward }

/// Reads one two-finger gesture on a touchpad as back or forward.
///
/// Fingers moving right are back, left are forward — what a browser on
/// Windows does with the same gesture, so the hand already knows it. A
/// gesture fires at most once, and only while it is plainly sideways: one that
/// has gone up or down first is somebody scrolling a chat, and stays that.
class TouchpadSwipeDetector {
  TouchpadSwipeDetector({this.distance = 140});

  /// How far the fingers travel sideways before it counts.
  final double distance;

  /// Up or down this far before the sideways distance is reached, it is a
  /// scroll for the rest of the gesture.
  static const double _scrollLock = 40;

  Offset _pan = Offset.zero;
  bool _done = false;

  void start() {
    _pan = Offset.zero;
    _done = false;
  }

  SwipeDirection? update(Offset panDelta, {double scale = 1}) {
    if (_done) return null;
    if ((scale - 1).abs() > 0.05) {
      _done = true; // a pinch
      return null;
    }
    _pan += panDelta;
    final dx = _pan.dx.abs();
    final dy = _pan.dy.abs();
    if (dy > _scrollLock && dy > dx) {
      _done = true;
      return null;
    }
    if (dx < distance || dx < dy * 2) return null;
    _done = true;
    return _pan.dx > 0 ? SwipeDirection.back : SwipeDirection.forward;
  }
}

/// Listens for [TouchpadSwipeDetector]'s gesture over [child] without taking
/// any pointer event from it: lists still scroll, and nothing below changes
/// how it behaves.
///
/// Windows hands a precision touchpad's two-finger movement to Flutter as
/// pan-zoom events, which is all this reads — a mouse wheel tilted sideways
/// is not a swipe.
class TouchpadSwipe extends StatefulWidget {
  const TouchpadSwipe({
    super.key,
    required this.onBack,
    required this.onForward,
    required this.child,
  });

  final VoidCallback onBack;
  final VoidCallback onForward;
  final Widget child;

  @override
  State<TouchpadSwipe> createState() => _TouchpadSwipeState();
}

class _TouchpadSwipeState extends State<TouchpadSwipe> {
  final _detector = TouchpadSwipeDetector();

  void _update(PointerPanZoomUpdateEvent e) {
    switch (_detector.update(e.panDelta, scale: e.scale)) {
      case SwipeDirection.back:
        widget.onBack();
      case SwipeDirection.forward:
        widget.onForward();
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerPanZoomStart: (_) => _detector.start(),
      onPointerPanZoomUpdate: _update,
      child: widget.child,
    );
  }
}
