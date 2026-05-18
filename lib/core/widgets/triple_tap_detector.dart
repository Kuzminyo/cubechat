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
      child: widget.child,
    );
  }
}
