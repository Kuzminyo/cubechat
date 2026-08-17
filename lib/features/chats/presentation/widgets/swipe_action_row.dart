import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/routing/back_gesture.dart';
import '../../data/swipe_action_controller.dart';

/// A chat row that reveals one action when dragged to the right.
///
/// **Rightward only, and that is what makes it possible at all.** The row sits
/// inside the strip of tab branches, whose own horizontal drag covers the whole
/// screen; a two-way swipe here would have taken every sideways gesture on the
/// chat list away from it. Claiming one direction leaves the other alone, so
/// swiping right archives a chat and swiping left still walks to the next tab.
/// See [RightwardDragRecognizer].
///
/// One action rather than a tray of them. A tray has to be held open while you
/// read it, which is two gestures for something whose whole appeal is being
/// one — and the full set of things you can do to a chat is already a long
/// press away. Which action this is belongs to the user; see [ChatSwipeAction].
class SwipeActionRow extends StatefulWidget {
  const SwipeActionRow({
    super.key,
    required this.action,
    required this.onFire,
    required this.child,
  });

  final ChatSwipeAction action;

  /// Run the action. Answers false when it was declined — a delete that was
  /// not confirmed — so the row can come back instead of staying open on a
  /// gesture that did nothing.
  final Future<bool> Function() onFire;

  final Widget child;

  /// How far the finger has to travel before releasing means "do it".
  static const double trigger = 84;

  /// The furthest the row will go, so a long drag does not tear it off the
  /// screen.
  static const double maxTravel = 108;

  @override
  State<SwipeActionRow> createState() => _SwipeActionRowState();
}

class _SwipeActionRowState extends State<SwipeActionRow>
    with SingleTickerProviderStateMixin {
  /// Where the row is. A notifier rather than setState for the same reason the
  /// message bubble's swipe uses one: this changes at frame rate under a
  /// finger, and rebuilding a whole chat row — avatar, preview, badges — a
  /// hundred times a second to move it sideways is what makes a swipe tear.
  final ValueNotifier<double> _offset = ValueNotifier<double>(0);

  /// Built in [initState], **not** as a `late final`.
  ///
  /// A lazy field is created on first *access*, and nothing in `build` touches
  /// this one — it only comes up when a finger releases mid-swipe. So on every
  /// row nobody swiped, the first access was `dispose()` calling
  /// `_spring.dispose()`, which constructed the controller there and then; the
  /// vsync it takes looks up `TickerMode` on an element that has already been
  /// deactivated, and the tree finalises with "looking up a deactivated
  /// widget's ancestor is unsafe". Nine test files caught it at once, which is
  /// the only reason it did not ship.
  late final AnimationController _spring;

  double _from = 0;

  /// True once a release would fire, held apart from the offset so crossing the
  /// line can tick exactly once.
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    _spring = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(() {
        if (_from == 0) return;
        _offset.value =
            _from * (1 - Curves.easeOutCubic.transform(_spring.value));
      });
  }

  @override
  void dispose() {
    _spring.dispose();
    _offset.dispose();
    super.dispose();
  }

  void _onUpdate(DragUpdateDetails d) {
    _spring.stop();
    final next =
        (_offset.value + d.delta.dx).clamp(0.0, SwipeActionRow.maxTravel);
    final armed = next >= SwipeActionRow.trigger;
    if (armed != _armed) HapticFeedback.selectionClick();
    _offset.value = next;
    _armed = armed;
  }

  Future<void> _onEnd() async {
    final fire = _armed;
    _armed = false;
    if (fire) {
      HapticFeedback.mediumImpact();
      // Home first, then act. The action can put up a dialog or take the row
      // out of the list altogether, and a row that is still held open while
      // that happens is a row that snaps back from nowhere afterwards.
      _springHome();
      await widget.onFire();
      return;
    }
    _springHome();
  }

  void _springHome() {
    _from = _offset.value;
    if (_from != 0) _spring.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.action == ChatSwipeAction.none) return widget.child;

    return RawGestureDetector(
      gestures: <Type, GestureRecognizerFactory>{
        RightwardDragRecognizer:
            GestureRecognizerFactoryWithHandlers<RightwardDragRecognizer>(
          RightwardDragRecognizer.new,
          (r) => r
            // From where the finger went down, not from where the arena was
            // won. The default throws away the travel spent deciding, so the
            // row starts a slop's worth behind the thumb and never catches up —
            // which reads as the gesture being sluggish or not working at all.
            ..dragStartBehavior = DragStartBehavior.down
            ..onUpdate = _onUpdate
            ..onEnd = ((_) => _onEnd())
            ..onCancel = _onEnd,
        ),
      },
      child: ValueListenableBuilder<double>(
        valueListenable: _offset,
        // Built once and handed through: a frame of the drag costs one
        // translate and the panel behind it, and nothing else.
        child: widget.child,
        builder: (context, offset, child) {
          return Stack(
            children: [
              if (offset > 1)
                Positioned.fill(
                  child: _ActionPanel(
                    action: widget.action,
                    progress: (offset / SwipeActionRow.trigger).clamp(0.0, 1.0),
                  ),
                ),
              Transform.translate(
                offset: Offset(offset, 0),
                child: child,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// What is revealed under the row as it moves.
///
/// The icon grows as the drag approaches the threshold and stops growing
/// exactly when releasing would fire, so "will this work?" is answered by
/// looking rather than by trying — the same rule the reply-swipe hint follows.
class _ActionPanel extends StatelessWidget {
  const _ActionPanel({required this.action, required this.progress});

  final ChatSwipeAction action;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final color = action.color;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 18),
        child: Opacity(
          opacity: (progress * 1.4).clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 0.7 + 0.3 * progress,
            child: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.22),
                border: Border.all(color: color.withValues(alpha: 0.6)),
              ),
              child: Icon(action.icon, size: 20, color: color),
            ),
          ),
        ),
      ),
    );
  }
}
