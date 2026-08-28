import 'dart:async';

import 'package:flutter/material.dart';

/// Wraps [child] so that three quick taps fire [onTripleTap].
///
/// The taps must arrive within [window] of each other; otherwise the counter
/// resets. Useful for hidden destructive actions like Emergency Wipe —
/// hard enough to do by accident, easy enough to do on purpose.
class TripleTapDetector extends StatefulWidget {
  const TripleTapDetector({
    super.key,
    required this.child,
    required this.onTripleTap,
    this.window = const Duration(milliseconds: 800),
  });

  final Widget child;
  final VoidCallback onTripleTap;
  final Duration window;

  @override
  State<TripleTapDetector> createState() => _TripleTapDetectorState();
}

class _TripleTapDetectorState extends State<TripleTapDetector> {
  int _taps = 0;
  Timer? _resetTimer;

  void _handleTap() {
    _resetTimer?.cancel();
    _taps++;
    if (_taps >= 3) {
      _taps = 0;
      widget.onTripleTap();
      return;
    }
    _resetTimer = Timer(widget.window, () => _taps = 0);
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      // Invisible to a screen reader, on purpose.
      //
      // A `GestureDetector` with an `onTap` publishes a tap action, so the app
      // title on the chats list was announced as something you could activate
      // — and activating it did nothing, because one tap out of three is not
      // the gesture. Flutter's own tap-target audit caught it as a 216x44 node
      // that claims to be tappable, which is precisely what it is.
      //
      // > **Design guideline — Accessibility > Mobility**: "Offer alternatives
      // > to gestures. Make sure your UI's core functionality is accessible
      // > through more than one type of physical interaction."
      //
      // The alternative is what makes this safe to hide rather than something
      // to expose properly: Emergency Wipe is a labelled button on the profile
      // screen, with the same confirmation. This detector is the shortcut, and
      // a shortcut nobody can perform should not be announced as a control.
      excludeFromSemantics: true,
      child: widget.child,
    );
  }
}
