import 'package:cubechat/features/desktop/touchpad_swipe.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two fingers across a laptop's touchpad: right for back, left for forward,
/// the way a browser on Windows reads them. Asked for on 2026-10-11.
void main() {
  group('the detector', () {
    SwipeDirection? run(List<Offset> deltas, {double scale = 1}) {
      final d = TouchpadSwipeDetector()..start();
      SwipeDirection? fired;
      for (final delta in deltas) {
        fired ??= d.update(delta, scale: scale);
      }
      return fired;
    }

    test('fingers to the right are back, to the left forward', () {
      expect(run(List.filled(10, const Offset(20, 0))), SwipeDirection.back);
      expect(
        run(List.filled(10, const Offset(-20, 1))),
        SwipeDirection.forward,
      );
    });

    test('a short nudge is nothing', () {
      expect(run(List.filled(3, const Offset(20, 0))), isNull);
    });

    test('a scroll that drifts sideways stays a scroll', () {
      expect(
        run([
          ...List.filled(5, const Offset(0, 30)),
          ...List.filled(10, const Offset(30, 0)),
        ]),
        isNull,
        reason: 'once a gesture has gone up or down it is reading the chat',
      );
    });

    test('a pinch is not a swipe', () {
      expect(run(List.filled(10, const Offset(20, 0)), scale: 1.3), isNull);
    });

    test('one gesture fires once', () {
      final d = TouchpadSwipeDetector()..start();
      final fired = [
        for (var i = 0; i < 30; i++) d.update(const Offset(20, 0)),
      ].whereType<SwipeDirection>();
      expect(fired, [SwipeDirection.back]);
    });
  });

  testWidgets('the widget hears a touchpad pan and calls back',
      (tester) async {
    var back = 0;
    var forward = 0;
    await tester.pumpWidget(
      TouchpadSwipe(
        onBack: () => back++,
        onForward: () => forward++,
        child: const SizedBox.expand(),
      ),
    );
    final pad = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pad.panZoomStart(const Offset(400, 300)));
    for (var x = 20.0; x <= 200; x += 20) {
      await tester.sendEventToBinding(pad.panZoomUpdate(
        const Offset(400, 300),
        pan: Offset(x, 0),
      ));
    }
    await tester.sendEventToBinding(pad.panZoomEnd());
    expect(back, 1);
    expect(forward, 0);
  });
}
