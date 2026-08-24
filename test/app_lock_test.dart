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
}
