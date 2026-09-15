import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/scheduler.dart';
import 'package:go_router/go_router.dart';

import '../util/motion.dart';
import '../util/transition_probe.dart';
import 'back_gesture.dart';

/// How a pushed screen arrives, leaves, and is dragged back.
///
/// This is Cupertino's page transition, on both platforms and deliberately.
/// Not for the look — the slide it gives is the one this app already wanted,
/// sideways with the screen underneath stepping back — but for the two things
/// a hand-rolled `CustomTransitionPage` cannot have:
///
///  * **A back gesture.** Pull from the left edge and the screen follows the
///    finger, at the distance the finger put it, and the one underneath comes
///    forward with it. Let go past halfway and it leaves; let go short and it
///    springs back. The transition machinery for that is worth not
///    reimplementing: the route has to hand its own animation over to a drag,
///    reclaim it on release, and stay correct if a second push arrives
///    mid-gesture. The *detector* is replaced — see [EdgeBackGesture] for why
///    Flutter's 20-pixel strip is unreachable on an Android phone.
///  * **Interruptibility.** A tween driven by a fixed-duration controller
///    cannot be caught halfway; every "jumpy" transition in this app was one of
///    those being restarted from wherever it happened to be.
///
/// The name stays [fadeSlidePage] because forty call sites use it and none of
/// them care how it moves.
Page<T> fadeSlidePage<T>({
  required Widget child,
  required GoRouterState state,
  Duration? duration,
  Duration? reverseDuration,
}) {
  return _SlidePage<T>(key: state.pageKey, child: child);
}

/// Cupertino's route, at this app's pace.
///
/// [CupertinoPage] would do everything here except the timing: iOS spends
/// 400 ms on a push, which next to a 240 ms tab strip and a 260 ms sheet reads
/// as the app hesitating. Everything else — the parallax, the shadow on the
/// leading edge, the edge-drag that hands the animation to your thumb — comes
/// from the mixin, because those are the parts worth not reimplementing.
class _SlidePage<T> extends Page<T> {
  const _SlidePage({required this.child, super.key});

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) =>
      _SlideRoute<T>(builder: (_) => child, settings: this);
}

/// The same screen transition, for a screen pushed by hand.
///
/// Everything routed through go_router already gets [fadeSlidePage] and with it
/// the edge drag. A handful of full-screen screens are pushed imperatively
/// instead — the channel form, the calendar, the forward picker — and those
/// went out on [mediaRoute], which fades. A fade has nothing for a thumb to
/// pull on, so those screens had a back button and no back gesture, which is
/// the one inconsistency you feel rather than see.
///
/// Same route, same drag, same 300 ms. Media keeps [mediaRoute]: a photo is not
/// the next screen along, and it has its own pull-down to close.
PageRoute<T> screenRoute<T>(WidgetBuilder builder) =>
    _SlideRoute<T>(builder: builder);

class _SlideRoute<T> extends PageRoute<T> with CupertinoRouteTransitionMixin<T> {
  _SlideRoute({required WidgetBuilder builder, super.settings})
      : _builder = builder;

  final WidgetBuilder _builder;

  @override
  Widget buildContent(BuildContext context) => _builder(context);

  @override
  Duration get transitionDuration =>
      TransitionProbe.instance.instantTransitions.value
          ? Duration.zero
          : const Duration(milliseconds: 300);

  /// Leaving takes longer than arriving.
  ///
  /// Both were 300 ms, because `reverseTransitionDuration` simply repeats the
  /// forward one unless it is given its own answer. But the two are not the
  /// same event. A push is a thing appearing and has to announce itself
  /// quickly, or the tap feels unanswered. A pop is a thing being put back,
  /// and at the same speed it reads as being snatched away — the screen you
  /// were reading is gone before the eye has finished leaving it.
  ///
  /// 380 ms is the pace the back gesture's release already settles at, so a
  /// close by button and a close by thumb now agree instead of being two
  /// different speeds for one action.
  ///
  /// Both collapse to nothing under the Diagnostics experiment that measures
  /// the same open without a slide - see [TransitionProbe.instantTransitions].
  @override
  Duration get reverseTransitionDuration =>
      TransitionProbe.instance.instantTransitions.value
          ? Duration.zero
          : const Duration(milliseconds: 380);

  @override
  String? get title => null;

  @override
  bool get maintainState => true;

  /// The slide is timed from the first frame after the page was built.
  ///
  /// See [_TimedFromFirstFrame]: the frame that builds a conversation is the
  /// longest one of the whole open, and the controller was counting it as
  /// part of the slide.
  @override
  Animation<double> createAnimation() =>
      _TimedFromFirstFrame(super.createAnimation());

  /// What the page underneath does while this one slides over it: Cupertino's
  /// step aside, drawn from a snapshot. See [_StillWhileCovered].
  ///
  /// This is the path the tabs take — the shell is a Material page, and a
  /// Material page hands its outgoing motion to the route arriving on top of
  /// it. A static tear-off, so every one of these routes compares equal and a
  /// conversation over a conversation keeps using [buildTransitions].
  @override
  DelegatedTransitionBuilder? get delegatedTransition => _stepAside;

  static Widget? _stepAside(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) =>
      CupertinoPageTransition.delegatedTransition(
        context,
        animation,
        secondaryAnimation,
        allowSnapshotting,
        child == null
            ? null
            : _StillWhileCovered(
                covering: secondaryAnimation,
                enabled: allowSnapshotting,
                child: child,
              ),
      );

  /// The mixin's own transition, with a reachable drag strip in place of its
  /// 20-pixel one.
  ///
  /// [CupertinoPageTransition] is kept exactly as it is — the parallax, the
  /// shadow on the leading edge, and `linearTransition`, which is what makes
  /// the page track the finger instead of easing while it is being dragged.
  /// Only the detector changes, because that is where the problem was: a strip
  /// too narrow to hit, in the one place Android's own gesture navigation
  /// already takes the touch. See [EdgeBackGesture].
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final content = _StillWhileCovered(
      // This page being covered or uncovered by another one of these — a
      // profile over a conversation. Under the shell's own page the same job
      // is done by [delegatedTransition].
      covering: secondaryAnimation,
      enabled: allowSnapshotting,
      child: RepaintBoundary(
        child: EdgeBackGesture(
          enabledCallback: () => popGestureEnabled,
          onStartGesture: () => EdgeBackGestureController(
            navigator: navigator!,
            controller: controller!,
            isCurrent: () => isCurrent,
            isActive: () => isActive,
          ),
          child: child,
        ),
      ),
    );

    // Reduce Motion replaces the travel, it does not remove the transition.
    //
    // > **Design guideline — Accessibility > Cognitive**: "Replacing
    // > transitions in x-, y-, and z-axes with fades to avoid motion."
    //
    // So the screen still announces itself, it just arrives in place instead
    // of sliding in from the side and dragging the one underneath with it.
    // The edge gesture stays wired up: it is the only way back on a screen
    // whose back button is a small target, and a fade under a thumb is still a
    // pop that can be started and abandoned.
    if (AppMotion.reduced(context)) {
      return FadeTransition(opacity: animation, child: content);
    }

    return CupertinoPageTransition(
      primaryRouteAnimation: animation,
      secondaryRouteAnimation: secondaryAnimation,
      linearTransition: popGestureInProgress,
      // Rasterised once, then carried.
      //
      // A transition slides two whole screens across each other, and without a
      // boundary each of them is repainted from its widgets on every frame of
      // it — a conversation means its wallpaper, its list, its panes, all
      // redrawn thirty or sixty times to be shown at a different x. The frames
      // caught next to a `[NAV] pop` were raster-bound at 35 ms against 3.9 ms
      // of build, which is that: no Dart work, a great deal of drawing.
      //
      // Inside the boundary the page becomes one layer the compositor can
      // translate, so the same pixels are moved rather than made again. It
      // works here specifically because everything that would keep dirtying
      // that layer has already been stopped for the length of the transition:
      // the aurora parks and the panes stop sampling their backdrop.
      //
      // Costs one full-screen layer per route while it moves, which is the
      // trade being made and is why this is not simply left on: a boundary
      // around something that repaints anyway is pure loss.
      //
      // **Inside the clip, not outside it.** It was outside first and bought
      // nothing measurable: closing a chat still read raster 44.6 ms against
      // build 1.6. [_RoundedWhileMoving] animates its corner radius every
      // frame, and a clip that changes forces its child to be rasterised
      // again — so a boundary above the clip is a boundary above something
      // that is being invalidated sixty times a second, which is precisely the
      // "pure loss" case named above. Below it, the page rasterises once and
      // the clip works on the finished layer.
      child: _RoundedWhileMoving(
        primary: animation,
        secondary: secondaryAnimation,
        child: content,
      ),
    );
  }
}

/// A route's opening slide, restarted on the first frame after the one that
/// built the page.
///
/// A ticker started inside a frame takes *that frame's* timestamp as its zero
/// (`Ticker.start`). A push through the router lands in the build of the frame
/// that also builds the new page, so the slide's clock was already running
/// while that build ran — and for a conversation it is the heaviest frame of
/// the open: build 17-35 ms on build 1054, against 1.5 ms of raster. The frame
/// after it then shows the page where 25 ms of slide would have put it, and on
/// [Curves.fastEaseInToSlowEaseOut] that is 18% of the way across as the very
/// first thing seen, where a steady 120 Hz start moves it 3% a frame. Reported
/// as the jerk when a chat opens, glass tier or not.
///
/// So the first tick after the build is taken as the start, and the rest of
/// the run is stretched to fit: the page leaves the edge one frame later than
/// it did, and arrives on time. The heavy frame becomes a pause before the
/// motion instead of a jump inside it — and it does not matter any more how
/// long it was.
///
/// Only the opening run. Once the push has finished, or was turned back before
/// it did, this is the controller's own value again, so a back swipe follows
/// the finger exactly.
class _TimedFromFirstFrame extends Animation<double>
    with AnimationWithParentMixin<double> {
  _TimedFromFirstFrame(this.parent) {
    parent
      ..addListener(_onTick)
      ..addStatusListener(_onStatus);
    // After the frame that builds the page — whether the push came inside that
    // frame (the router) or before it (a tap handler calling push).
    SchedulerBinding.instance.addPostFrameCallback((_) => _built = true);
  }

  @override
  final Animation<double> parent;

  bool _built = false;
  bool _settled = false;

  /// The controller's value on the first frame after the build, while the
  /// opening run is going; null otherwise.
  double? _start;

  void _onTick() {
    if (!_built || _settled) return;
    parent.removeListener(_onTick);
    if (parent.status == AnimationStatus.forward && parent.value < 1) {
      _start = parent.value;
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.forward ||
        status == AnimationStatus.reverse) {
      return;
    }
    _settled = true;
    _start = null;
    parent
      ..removeListener(_onTick)
      ..removeStatusListener(_onStatus);
  }

  @override
  double get value {
    final raw = parent.value;
    final start = _start;
    if (start == null) return raw;
    return ((raw - start) / (1 - start)).clamp(0.0, 1.0);
  }
}

/// The page underneath a slide, drawn from one picture of itself while the
/// slide runs.
///
/// Build 1055 put numbers on the slide itself: the GPU thread, not Dart, was
/// the cost of opening and closing a conversation. Raster p95 9.8 ms over
/// twelve opens of a chat with photos and circles, 15.3 ms for one with
/// circles, against 5-7 ms for a plain screen and a 120 Hz budget of 8.3 —
/// seven to eleven frames over budget in every forty-frame slide, and slow
/// frames of 17-18 ms raster beside 0.9 ms of build when chats were opened and
/// closed in a row. GPU raster was 29-41% of a core against 14-20% for Dart.
///
/// A slide draws two whole screens on every frame: the one arriving and the
/// one it covers, each with its aurora, its panes and its rows. The
/// [RepaintBoundary] below does not save that on this renderer — Impeller
/// keeps no raster cache, so a layer that did not change is still drawn from
/// its display list every frame. The page underneath does not change while it
/// is being covered, though: the chat list hands back its last tree and waits
/// for the slide to end before catching up, the panes stop sampling and the
/// aurora parks. So it is painted once into a texture and that texture is what
/// moves — the same thing Material's own zoom transition does, through the
/// same [SnapshotWidget].
///
/// Only while it is moving. At rest the page is live, and fully covered it is
/// not painted at all. Never for the page that is arriving, whose first frames
/// are still settling (a scroll restored, pictures landing) and would be
/// re-snapshotted or shown stale. A platform view underneath (the map) cannot
/// be snapshotted and is painted as before — that is what `permissive` means.
///
/// Always built, never inserted: a wrapper that comes and goes changes the
/// shape of the tree, and that tears the page down — see [_RoundedWhileMoving].
class _StillWhileCovered extends StatefulWidget {
  const _StillWhileCovered({
    required this.covering,
    required this.enabled,
    required this.child,
  });

  /// The route on top's progress, as this page sees it.
  final Animation<double> covering;

  /// The route's own `allowSnapshotting`.
  final bool enabled;

  final Widget child;

  @override
  State<_StillWhileCovered> createState() => _StillWhileCoveredState();
}

class _StillWhileCoveredState extends State<_StillWhileCovered> {
  final _snapshot = SnapshotController();

  @override
  void initState() {
    super.initState();
    widget.covering.addStatusListener(_onStatus);
    _update();
  }

  @override
  void didUpdateWidget(_StillWhileCovered oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.covering, widget.covering)) {
      oldWidget.covering.removeStatusListener(_onStatus);
      widget.covering.addStatusListener(_onStatus);
    }
    _update();
  }

  @override
  void dispose() {
    widget.covering.removeStatusListener(_onStatus);
    _snapshot.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus _) => _update();

  void _update() =>
      _snapshot.allowSnapshotting = widget.enabled && widget.covering.isAnimating;

  @override
  Widget build(BuildContext context) => SnapshotWidget(
        controller: _snapshot,
        mode: SnapshotMode.permissive,
        autoresize: true,
        child: widget.child,
      );
}

/// Rounds a page's corners for exactly as long as it is moving.
///
/// A screen sliding over another with square corners reads as one flat thing
/// being replaced by another flat thing. Rounded while it travels — and rounded
/// on the page underneath as it recedes — the two read as sheets, one lifted
/// over the other, which is the whole feeling of dragging one back with a
/// thumb.
///
/// Costs nothing at rest, deliberately. A clip is not free: it forces a save
/// layer for everything inside it, on every frame, on the most-scrolled screens
/// in the app. So the radius is a function of how far the page is from settled
/// — [primary] below 1 while it arrives or leaves, [secondary] above 0 while
/// something covers it — and at zero radius `clipBehavior: Clip.none` paints
/// the child straight through with no layer at all.
///
/// The clip is always *built*, though, which is the whole point of the
/// `Clip.none` rather than returning the child bare. Swapping between "child"
/// and "clip wrapping child" changes the shape of the tree, and Flutter answers
/// that by tearing down everything below it and inflating it again — including
/// the back-gesture detector and the entire page. That is what made the drag
/// unusable: it started, moved one frame, and then the recognizer driving it
/// was disposed mid-gesture, so the page stopped following the finger and
/// sprang back. A structural change is not a cheap way to save a save layer.
class _RoundedWhileMoving extends StatelessWidget {
  const _RoundedWhileMoving({
    required this.primary,
    required this.secondary,
    required this.child,
  });

  final Animation<double> primary;
  final Animation<double> secondary;
  final Widget child;

  static const double _radius = 22;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([primary, secondary]),
      child: child,
      builder: (context, inner) {
        final travelling = math.max(
          1 - primary.value.clamp(0.0, 1.0),
          secondary.value.clamp(0.0, 1.0),
        );
        final radius = _radius * travelling;
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          // `hardEdge` while it travels, not `antiAlias`.
          //
          // Antialiasing a rounded clip is the expensive kind: on a tiled
          // mobile GPU it needs coverage per edge pixel and its own pipeline,
          // and that pipeline is compiled the first time it is used — which is
          // the first route transition of the app run. "Opening a chat lags
          // the first couple of times and then it is fine" is what a pipeline
          // being compiled on the frame that needs it feels like, and the
          // frames caught next to a `[NAV]` line were raster-bound at 34-43 ms
          // against builds of 1.6 to 8.9.
          //
          // Nothing is lost from the animation: the same corner, the same
          // radius, the same 300 ms, on the common pipeline instead of the
          // rare one. What hard edges cost is a stair-step of at most a pixel
          // on a 22-pixel corner, for the length of a slide, on a shape that
          // is moving across the screen while it is on show.
          clipBehavior: radius < 0.5 ? Clip.none : Clip.hardEdge,
          child: inner,
        );
      },
    );
  }
}

/// How a full-screen picture opens: a fade with a whisper of scale.
///
/// Not a side-slide — a photo, the editor and the camera are not "the next
/// screen along", they are the same thing at a different size, and sliding one
/// in from the edge says otherwise. What they must not do is what they did:
/// appear and vanish outright, which is the closing everyone described as
/// abrupt because there was nothing there at all.
PageRoute<T> mediaRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 300),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    opaque: false,
    // No barrier of its own. Every screen opened this way paints its own black
    // background, so the barrier only ever duplicated it — and being a fixed
    // colour on the route, it could not get out of the way when one of those
    // screens wants to reveal what is underneath. Which is exactly what
    // swipe-down-to-close needs: the conversation showing through as the
    // picture is pulled towards it.
    barrierColor: null,
    pageBuilder: (context, animation, secondary) => builder(context),
    transitionsBuilder: (context, animation, secondary, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}
