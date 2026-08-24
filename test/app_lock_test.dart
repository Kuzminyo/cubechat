import 'dart:io';

import 'package:cubechat/features/profile/data/app_lock_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// The lock that stands between a person holding the phone and the messages on
/// it. Optional, off by default, and the only control in this app aimed at
/// somebody who already has the device in their hand.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_lock_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  Future<AppLockController> lock(ProviderContainer container) async {
    final l = container.read(appLockControllerProvider.notifier);
    await l.loaded;
    return l;
  }

  test('a fresh install has no lock and never asks', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final l = await lock(container);

    expect(container.read(appLockControllerProvider).enabled, isFalse);
    expect(container.read(appLockControllerProvider).locked, isFalse);
    // Leaving and coming back cannot lock what was never locked.
    l.noteLeft();
    l.noteReturned();
    expect(container.read(appLockControllerProvider).locked, isFalse);
  });

  test('the right code opens it and a wrong one does not', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final l = await lock(container);

    expect(await l.enable('4821'), isTrue);
    expect(container.read(appLockControllerProvider).enabled, isTrue);

    // Locked by hand, as a return from a long absence would.
    l.noteLeft();
    await Future<void>.delayed(Duration.zero);
    expect(await l.unlock('0000'), isFalse,
        reason: 'a wrong code must not open it');
    expect(await l.unlock('4821'), isTrue);
    expect(container.read(appLockControllerProvider).locked, isFalse);
  });

  test('a code too short to be a code is refused', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final l = await lock(container);

    expect(await l.enable('12'), isFalse);
    expect(container.read(appLockControllerProvider).enabled, isFalse,
        reason: 'a refused code must not leave the lock half on');
  });

  test('turning it off needs the current code', () async {
    // Otherwise the lock is a suggestion anybody holding the phone can
    // decline from the settings screen.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final l = await lock(container);

    await l.enable('4821');
    expect(await l.disable('1111'), isFalse);
    expect(container.read(appLockControllerProvider).enabled, isTrue);
    expect(await l.disable('4821'), isTrue);
    expect(container.read(appLockControllerProvider).enabled, isFalse);
  });

  test('a glance away does not ask again, a real absence does', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final l = await lock(container);
    await l.enable('4821');

    // Backgrounding asks, every time. This reverses what the test said
    // before, on purpose and on request: the grace was thirty seconds, which
    // made the lock look broken — minimise, come back in five seconds, and
    // nothing happened.
    //
    // The concern the grace existed for is still handled, one layer up: a
    // notification shade or a permission dialog is `inactive`, and only
    // `paused` and `hidden` reach [noteLeft] at all. So this asks when the app
    // was actually left, and not for a glance at something on top of it.
    l.noteLeft();
    l.noteReturned();
    expect(container.read(appLockControllerProvider).locked, isTrue);
  });

  test('nothing to come back from leaves it alone', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final l = await lock(container);
    await l.enable('4821');

    // Resumed without having been left — the first frames of a launch emit
    // this, and it must not lock a session the user just unlocked.
    l.noteReturned();
    expect(container.read(appLockControllerProvider).locked, isFalse);
  });

  test('a wipe leaves nothing to ask for', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final l = await lock(container);
    await l.enable('4821');

    await l.reset();
    expect(container.read(appLockControllerProvider).enabled, isFalse);
    expect(await l.verify('4821'), isFalse,
        reason: 'the stored hash has to go with it');
  });

  test('three wrong codes are free, the fourth costs', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final l = await lock(container);
    await l.enable('4821');

    // Three is how often a person mistypes a code they know.
    for (var i = 0; i < 3; i++) {
      expect(await l.unlock('0000'), isFalse);
      expect(container.read(appLockControllerProvider).isPenalised, isFalse);
    }

    expect(await l.unlock('0000'), isFalse);
    final state = container.read(appLockControllerProvider);
    expect(state.isPenalised, isTrue);
    expect(state.penaltyLeft.inSeconds, greaterThan(25));
  });

  test('the right code is refused while the wait is running', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final l = await lock(container);
    await l.enable('4821');

    for (var i = 0; i < 4; i++) {
      await l.unlock('0000');
    }

    // Checking the code first would make the wait a rate limit somebody can
    // sit out while still learning, one guess per window, whether they were
    // right.
    expect(await l.unlock('4821'), isFalse);
    expect(container.read(appLockControllerProvider).isPenalised, isTrue);
  });

  test('hammering during the wait does not lengthen it', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final l = await lock(container);
    await l.enable('4821');

    for (var i = 0; i < 4; i++) {
      await l.unlock('0000');
    }
    final first = container.read(appLockControllerProvider).penaltyLeft;
    final attempts = container.read(appLockControllerProvider).wrongAttempts;

    // A refused try is not a try. Counting them would let anything tapping in
    // a loop drive the wait to its maximum in a second, which punishes the
    // owner who came back and typed once while the wait was still on.
    for (var i = 0; i < 5; i++) {
      await l.unlock('0000');
    }
    final after = container.read(appLockControllerProvider);
    expect(after.wrongAttempts, attempts);
    expect(after.penaltyLeft, lessThanOrEqualTo(first));
  });

  test('the waits get longer, in order', () {
    // The escalation itself: each wrong code past the free three costs more
    // than the one before, and it stops growing rather than running away.
    final waits = AppLockController.penalties;
    for (var i = 1; i < waits.length; i++) {
      expect(waits[i], greaterThan(waits[i - 1]));
    }
    expect(waits.first, const Duration(seconds: 30));
  });

  test('a right code clears the count', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final l = await lock(container);
    await l.enable('4821');

    await l.unlock('0000');
    await l.unlock('0000');
    expect(await l.unlock('4821'), isTrue);
    expect(container.read(appLockControllerProvider).wrongAttempts, 0);
  });

  test('the grace decides whether coming back asks', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final l = await lock(container);
    await l.enable('4821');

    // A minute of grace: stepping out and back does not ask.
    await l.setGraceSeconds(60);
    l.noteLeft();
    l.noteReturned();
    expect(container.read(appLockControllerProvider).locked, isFalse);

    // Back to every time.
    await l.setGraceSeconds(0);
    l.noteLeft();
    l.noteReturned();
    expect(container.read(appLockControllerProvider).locked, isTrue);
  });
}
