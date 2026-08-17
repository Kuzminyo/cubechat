import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Container for the tab-shell branches: four screens side by side, and a
/// finger that drags between them.
///
/// Every branch stays mounted for the life of the shell, so switching tabs
/// costs nothing — no rebuild, no re-run of entrance animations, and scroll
/// positions, keyboards and half-typed messages all survive. What changes is
/// only where each one is drawn.
///
/// The motion is a strip, not a transition. An earlier version cross-faded the
/// outgoing branch into the incoming one and, later, slid the whole stack a few
/// points on top of that — two opacity layers over four full screens of glass
/// animating at once, which is a compositing bill paid by the phones that can
/// least afford it, and it looked like it. Sliding is far cheaper than fading
/// (a translation moves an already-rasterised layer; opacity forces an offscreen
/// buffer every frame) and it is also the truer gesture: the tabs are a row, the
/// bar says so, and a page that follows the thumb says the same thing without a
/// word.
class BranchContainer extends StatefulWidget {
  const BranchContainer({
    super.key,
    required this.currentIndex,
    required this.branches,
    required this.onSwitch,
  });

  final int currentIndex;
  final List<Widget> branches;

  /// Called once a drag has decided where it landed. The shell owns the branch
  /// navigators and is the only thing that can actually change tab — but it is
  /// also a go_router type that cannot be built in a test, and what this widget
  /// needs from it is one integer and one callback.
  final ValueChanged<int> onSwitch;

  @override
  State<BranchContainer> createState() => _BranchContainerState();
}

class _BranchContainerState extends State<BranchContainer>
    with SingleTickerProviderStateMixin {
  /// Where the strip is, measured in tabs. 1.5 means half way between Contacts
  /// and Nearby — a real position during a drag, not an interpolation between
  /// two states.
  late final AnimationController _page;

  /// The tab the strip is heading for, so a rebuild caused by our own
  /// `goBranch` does not restart the animation that called it.
  late int _target;

  bool _dragging = false;
  double _width = 1;

  @override
  void initState() {
    super.initState();
    // Both set here rather than as `late` field initialisers, which are
    // evaluated on first *access*: the first read of the target happened inside
    // didUpdateWidget, by which time `widget` was already the new one — so it
    // initialised to the tab we were being asked to move to, compared equal,
    // and the strip never moved at all.
    _target = widget.currentIndex;
    _page = AnimationController.unbounded(
      vsync: this,
      value: _target.toDouble(),
    )..addListener(_onPageChanged);
  }

  void _onPageChanged() => setState(() {});

  @override
  void didUpdateWidget(covariant BranchContainer old) {
    super.didUpdateWidget(old);
    final index = widget.currentIndex;
    // A tap on the bar, a deep link, a notification: something moved the tab
    // from outside this widget, so the strip has to catch up.
    //
    // Unconditionally — this used to stand aside while `_dragging` was set, and
    // that flag is only ever lowered by a drag that ends. A drag that does not
    // end (see [_onDragCancel]) therefore left the strip parked between two
    // screens *and* deaf to the one thing that could have rescued it: tapping
    // the tab you wanted. The bar lit up, the screens stayed half and half, and
    // the only thing that still worked was dragging by hand — which is exactly
    // how it was reported.
    //
    // Nothing legitimate is lost. Our own [_onDragEnd] sets `_target` before it
    // calls back, so the rebuild it causes compares equal and is ignored; any
    // other source of a new index is something the user asked for, and landing
    // on it is the right answer whatever the finger is doing.
    if (index != _target) {
      _dismissKeyboard();
      _dragging = false;
      _settleTo(index);
    }
  }

  /// Drop the keyboard on the way out of a tab.
  ///
  /// Branches stay mounted for the life of the shell — that is the whole point
  /// of the strip — and [Offstage] does not touch focus. So a field left
  /// focused in one tab (the Contacts search is the one that has one) kept its
  /// text-input connection open after the tab was gone, and the keyboard stayed
  /// up over whichever screen arrived next.
  ///
  /// On Android that was survivable: the system Back gesture dismisses a
  /// keyboard whether or not the app agrees. iOS has no such escape, and the
  /// field still holding focus was offstage and behind an [IgnorePointer], so
  /// there was nothing left to tap and no way to close it at all — reported,
  /// accurately, as "the keyboard won't go away".
  void _dismissKeyboard() => FocusManager.instance.primaryFocus?.unfocus();

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  void _settleTo(int index, {double velocity = 0}) {
    _target = index;
    final distance = (index - _page.value).abs();
    if (distance < 0.001) {
      _page.value = index.toDouble();
      return;
    }
    // Long enough to read as movement, short enough that a deliberate flick is
    // not held up. Scaled by how far is left, so releasing a nearly-finished
    // drag lands at once instead of crawling the last few pixels.
    final ms = (140 + 180 * distance).clamp(140, 320).round();
    _page.animateTo(
      index.toDouble(),
      duration: Duration(milliseconds: ms),
      curve: velocity.abs() > 600 ? Curves.easeOutCubic : Curves.easeOutQuart,
    );
  }

  void _onDragStart(DragStartDetails _) {
    _dragging = true;
    // The finger has started moving the strip, so the tab under it is already
    // on its way out. Dropping the keyboard here rather than on landing means
    // the screen being dragged in is uncovered while it slides, instead of
    // arriving behind a keyboard that belongs to the tab now off-screen.
    _dismissKeyboard();
    _page.stop();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final last = (widget.branches.length - 1).toDouble();
    // Dragging left moves the strip right, one screen width per tab. Clamped at
    // both ends rather than rubber-banded: there is nothing past Profile, and a
    // strip that stretches implies there is.
    _page.value = (_page.value - d.primaryDelta! / _width).clamp(0.0, last);
  }

  /// The finger is gone without an ending.
  ///
  /// A drag does not always finish: another recognizer can take the arena
  /// after we accepted it, and iOS's own edge-swipe does exactly that. Then
  /// `onHorizontalDragEnd` never arrives — and everything that settles the
  /// strip lived in it. So the tabs stopped mid-slide, showing half of each
  /// screen, and stayed there: `_dragging` was still true, which is also the
  /// flag that stops [didUpdateWidget] from catching up, so tapping the bar
  /// could not rescue it either. The tab could still be dragged by hand,
  /// because that path never needed the flag — which is precisely how it was
  /// reported.
  ///
  /// A cancel is treated as a release with no throw behind it: land on
  /// whichever tab the strip is nearest.
  void _onDragCancel() {
    if (!_dragging) return;
    _onDragEnd(DragEndDetails());
  }

  void _onDragEnd(DragEndDetails d) {
    _dragging = false;
    final velocity = d.primaryVelocity ?? 0;
    final last = widget.branches.length - 1;
    final from = widget.currentIndex;
    // A flick decides on its own, however short: past ~600 px/s the finger has
    // already said which way it is going, and waiting for it to cross the
    // halfway line would be ignoring that. Otherwise the nearest tab wins.
    final int index;
    if (velocity.abs() > 600) {
      index = (velocity < 0 ? from + 1 : from - 1).clamp(0, last);
    } else {
      index = _page.value.round().clamp(0, last);
    }
    _settleTo(index, velocity: velocity);
    // Immediately, not when the animation lands: the bar lighting up the tab
    // you are already looking at is what makes the gesture feel decided.
    if (index != from) widget.onSwitch(index);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth;
        final page = _page.value;
        return RawGestureDetector(
          // Horizontal only, so vertical scrolling inside a branch is never in
          // question. An inner horizontal scrollable — the folder pills, the
          // palette swatches — still wins the arena on its own turf, the same
          // way one inside a PageView does.
          behavior: HitTestBehavior.translucent,
          gestures: <Type, GestureRecognizerFactory>{
            _LazyHorizontalDragRecognizer:
                GestureRecognizerFactoryWithHandlers<
                    _LazyHorizontalDragRecognizer>(
              _LazyHorizontalDragRecognizer.new,
              (r) => r
                ..onStart = _onDragStart
                ..onUpdate = _onDragUpdate
                ..onEnd = _onDragEnd
                ..onCancel = _onDragCancel,
            ),
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              for (var i = 0; i < widget.branches.length; i++)
                _Branch(
                  offset: (i - page) * _width,
                  // Anything within one screen of the strip's position is on
                  // its way in or out; the rest is parked. Offstage keeps a
                  // branch mounted — its state and scroll offset survive —
                  // while skipping it in layout and paint, so the screens
                  // nobody is looking at cost nothing.
                  visible: (i - page).abs() < 1,
                  active: i == widget.currentIndex,
                  child: widget.branches[i],
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The tab strip's own drag, which waits longer than anything inside it.
///
/// It covers every pixel of every branch, so it is in the arena against every
/// horizontal gesture in the app — a chat row being swiped, a bubble being
/// pulled for a reply, a voice note being scrubbed. All of them are horizontal
/// drags, all accept at the ordinary touch slop, and a tie between two
/// recognizers that both accept on the same pointer move is not resolved in
/// favour of the inner one in any way worth relying on. What the strip won, the
/// row lost — and a chat row that will not swipe is exactly how that looks.
///
/// So this one holds off until the finger has travelled well past the slop. By
/// then whatever was under it has claimed the gesture and this recognizer is
/// already out of the arena; if nothing did, the drag is plainly a tab swipe
/// and a few extra millimetres is not a cost anybody notices.
///
/// The same trick, for the same reason, as the page-level back gesture — see
/// `EdgeBackGesture` in `back_gesture.dart`, which learned it first.
class _LazyHorizontalDragRecognizer extends HorizontalDragGestureRecognizer {
  _LazyHorizontalDragRecognizer({super.debugOwner});

  /// Far enough to be past anything an inner widget wants, short enough that a
  /// deliberate swipe between tabs still feels immediate.
  static const double _threshold = 44;

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    return globalDistanceMoved.abs() > _threshold;
  }
}

class _Branch extends StatelessWidget {
  const _Branch({
    required this.offset,
    required this.visible,
    required this.active,
    required this.child,
  });

  final double offset;
  final bool visible;
  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: !visible,
      child: Transform.translate(
        offset: Offset(offset, 0),
        // The branch rasterises once and is then moved as a finished layer,
        // which is the whole reason this is cheap enough to run under a finger.
        child: RepaintBoundary(
          child: IgnorePointer(
            // Only the tab you have landed on takes taps. Mid-drag the
            // neighbour is on screen but not yet yours.
            ignoring: !active,
            // Silences tickers inside a branch nobody can see — the aurora,
            // entrance animations — but leaves them running for whichever one
            // is sliding in, so it does not arrive frozen.
            child: TickerMode(enabled: visible, child: child),
          ),
        ),
      ),
    );
  }
}
