import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';

import '../util/motion.dart';
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

class _SlideRoute<T> extends PageRoute<T>
    with CupertinoRouteTransitionMixin<T> {
  _SlideRoute({required WidgetBuilder builder, super.settings})
      : _builder = builder;

  final WidgetBuilder _builder;

  @override
  Widget buildContent(BuildContext context) => _builder(context);

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

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
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 380);

  @override
  String? get title => null;

  @override
  bool get maintainState => true;

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
    final content = RepaintBoundary(
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
          scale: Tween<double>(
                  begin: AppMotion.reduced(context) ? 1 : 0.96, end: 1)
              .animate(curved),
          child: child,
        ),
      );
    },
  );
}
