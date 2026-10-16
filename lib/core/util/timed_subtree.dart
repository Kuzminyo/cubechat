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
