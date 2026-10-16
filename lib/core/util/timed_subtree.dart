import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'frame_stats.dart';

/// Times the layout and the paint recording of everything under it, into the
/// frame meter as `<label>.layout` and `<label>.paint`.
///
/// A build counter cannot see either: the frame's "build" number is the whole
/// UI-thread frame — widgets, then layout, then recording the paint — and most
/// of a conversation's first frame is text being measured, which happens in
/// layout. Layout here includes every descendant's, so nested timers overlap
/// by design: `chat.layout` contains `list.layout`.
class TimedSubtree extends SingleChildRenderObjectWidget {
  const TimedSubtree(this.label, {super.key, super.child});

  final String label;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTimed(label);

  @override
  void updateRenderObject(BuildContext context, _RenderTimed renderObject) {
    renderObject.label = label;
  }
}

/// Times building everything under it the first time, into the frame meter as
/// `<label>.inflate`.
///
/// A lazy list builds its rows *during its own layout*, so `list.layout`
/// above is two costs at once — creating every element and render object of
/// each row, and then measuring its text — and the two have different cures.
/// This separates the first: mounting an element builds its whole subtree
/// synchronously, so timing the mount times all of it.
class TimedInflate extends StatelessWidget {
  const TimedInflate(this.label, {super.key, required this.child});

  final String label;
  final Widget child;

  @override
  StatelessElement createElement() => _TimedInflateElement(this);

  @override
  Widget build(BuildContext context) => child;
}

class _TimedInflateElement extends StatelessElement {
  _TimedInflateElement(TimedInflate super.widget);

  @override
  void mount(Element? parent, Object? newSlot) {
    final watch = Stopwatch()..start();
    super.mount(parent, newSlot);
    FrameStats.countTime(
      '${(widget as TimedInflate).label}.inflate',
      watch.elapsedMicroseconds,
    );
  }
}

class _RenderTimed extends RenderProxyBox {
  _RenderTimed(this.label);

  String label;

  @override
  void performLayout() {
    final watch = Stopwatch()..start();
    super.performLayout();
    FrameStats.countTime('$label.layout', watch.elapsedMicroseconds);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final watch = Stopwatch()..start();
    super.paint(context, offset);
    FrameStats.countTime('$label.paint', watch.elapsedMicroseconds);
  }
}
