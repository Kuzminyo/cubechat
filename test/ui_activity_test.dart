import 'package:cubechat/core/util/ui_activity.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Decorative animations park themselves against this signal, so its edges
/// matter: stay quiet when it should be loud and the online dots freeze mid-use;
/// stay loud when it should be quiet and nothing was gained — the app keeps
/// scheduling a frame every vsync, which is the drain this exists to remove.
void main() {
  setUp(() {
    // flutter_test_config.dart disables the countdown for the whole suite, so
    // stray widget-test taps can't leave a pending timer. This file is the one
    // place that needs it running.
    UiActivity.debugDisableQuietTimer = false;
    UiActivity.instance.resetForTest();
  });
  tearDown(() {
    UiActivity.instance.resetForTest();
    UiActivity.debugDisableQuietTimer = true;
  });

  test('starts loud, so animations run before the first touch', () {
    // A freshly launched app has had no pointer events at all. If that read as
    // "quiet", every pulse would be frozen until the user happened to tap
    // something.
    expect(UiActivity.instance.isQuiet.value, isFalse);
  });

  test('goes quiet once nothing has been touched', () {
    fakeAsync((fa) {
      UiActivity.instance.poke();
      expect(UiActivity.instance.isQuiet.value, isFalse);

      fa.elapse(const Duration(seconds: 3));
      expect(UiActivity.instance.isQuiet.value, isFalse,
          reason: 'someone reading a conversation is still using the app');

      fa.elapse(const Duration(seconds: 2));
      expect(UiActivity.instance.isQuiet.value, isTrue);
    });
  });

  test('a touch wakes it again and restarts the countdown', () {
    fakeAsync((fa) {
      UiActivity.instance.poke();
      fa.elapse(const Duration(seconds: 5));
      expect(UiActivity.instance.isQuiet.value, isTrue);

      UiActivity.instance.poke();
      expect(UiActivity.instance.isQuiet.value, isFalse);

      // Not merely awake — the full quiet period has to run again from here,
      // or continuous scrolling would let it doze off mid-gesture.
      fa.elapse(const Duration(seconds: 3));
      expect(UiActivity.instance.isQuiet.value, isFalse);
      fa.elapse(const Duration(seconds: 2));
      expect(UiActivity.instance.isQuiet.value, isTrue);
    });
  });

  test('notifies only on a transition, not on every poke', () {
    fakeAsync((fa) {
      var notifications = 0;
      void count() => notifications++;
      UiActivity.instance.isQuiet.addListener(count);
      addTearDown(() => UiActivity.instance.isQuiet.removeListener(count));

      // A drag is a stream of pointer moves; each one pokes. None of them
      // change the answer, and a listener per dot per event would be worse
      // than the animation it replaces.
      for (var i = 0; i < 50; i++) {
        UiActivity.instance.poke();
        fa.elapse(const Duration(milliseconds: 16));
      }
      expect(notifications, 0);

      fa.elapse(const Duration(seconds: 5));
      expect(notifications, 1);
    });
  });
}
