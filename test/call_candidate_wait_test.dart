import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cubechat/features/call/data/call_candidate_wait.dart';

void main() {
  test('a usable relay is not blocked by an unfinished interface', () {
    fakeAsync((clock) {
      final gathered = Completer<void>(), relay = Completer<void>();
      var ready = false;
      waitForCallCandidates(gathered: gathered.future, relayReady: relay.future)
          .then((_) => ready = true);
      relay.complete();
      clock.flushMicrotasks();
      clock.elapse(const Duration(milliseconds: 399));
      expect(ready, isFalse);
      clock.elapse(const Duration(milliseconds: 1));
      expect(ready, isTrue);
    });
  });
  test('no route is a bounded failure, not a direct fallback', () {
    fakeAsync((clock) {
      Object? failure;
      waitForCallCandidates(
              gathered: Completer<void>().future,
              relayReady: Completer<void>().future)
          .catchError((Object e) {
        failure = e;
      });
      clock.elapse(const Duration(seconds: 12));
      expect(failure, isA<TimeoutException>());
    });
  });
}
