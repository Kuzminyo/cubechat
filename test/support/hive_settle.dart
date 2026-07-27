/// Let fire-and-forget storage work finish before a test tears its Hive
/// directory down.
///
/// Several controllers — and `MessagingService` above all — open encrypted Hive
/// boxes from constructors that cannot await them. A test that deletes its temp
/// directory the moment the body returns pulls the storage out from under those
/// opens, and the failure does not land anywhere catchable:
///
/// `HiveImpl._openBox` parks a `Completer`'s future in its `_openingBoxes` map,
/// and on failure calls `completer.completeError(...)` **and** rethrows. The
/// rethrow reaches our `try`/`catch`; the completer's copy has no listener
/// unless a second caller happened to be opening the same box, so Dart reports
/// it as an unhandled error in the surrounding zone. `package:test` attributes
/// that to whichever test is running — usually one that has already passed,
/// hence "This test failed after it had already completed".
///
/// Nothing in application code can catch it: it is not on any future we hold.
/// So the fix is to stop racing it. Without this the suite failed roughly one
/// run in two, on a different file each time.
library;

import 'dart:async';

/// Wait for in-flight background storage work, then let the caller close Hive.
///
/// Deliberately a plain delay: the futures involved are precisely the ones
/// nobody has a handle on, so there is nothing to await.
Future<void> settleBackgroundStorage() =>
    Future<void>.delayed(const Duration(milliseconds: 250));
