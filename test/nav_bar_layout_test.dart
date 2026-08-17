import 'dart:io';

import 'package:cubechat/features/profile/data/nav_bar_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

NavBarController _controller(ProviderContainer container) =>
    container.read(navBarControllerProvider.notifier);

ProviderContainer _fresh() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

void main() {
  // The controller persists through the encrypted settings box, so Hive has to
  // have somewhere to live even for the rules that never touch it — the load
  // runs on construction.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_navbar_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
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

  group('the default bar', () {
    test('is every destination in the router\'s own order', () {
      const layout = NavBarLayout.initial;
      expect(layout.shown, NavDestination.values);
      expect(layout.branches, [0, 1, 2, 3, 4]);
      expect(layout.isDefault, isTrue);
    });

    test('branch indices are the contract with the router', () {
      // StatefulShellRoute pairs branches to tabs by position, so these numbers
      // are not decoration — if they drift from app_router.dart, a tap lands on
      // somebody else's screen.
      expect(NavDestination.chats.branch, 0);
      expect(NavDestination.profile.branch, 4);
      expect(NavDestination.byBranch(2), NavDestination.peers);
      expect(NavDestination.byBranch(9), isNull);
    });
  });

  group('reordering', () {
    test('moves a tab and keeps the branch mapping in step', () async {
      final container = _fresh();
      await _controller(container).reorder(3, 0); // map to the front

      final layout = container.read(navBarControllerProvider);
      expect(layout.shown.first, NavDestination.map);
      expect(layout.branches.first, NavDestination.map.branch);
      // The position the shell should light up for the map's branch.
      expect(layout.positionOf(NavDestination.map.branch), 0);
      expect(layout.isDefault, isFalse);
    });

    test('an out-of-range index is ignored rather than throwing', () async {
      final container = _fresh();
      await _controller(container).reorder(99, 0);
      expect(container.read(navBarControllerProvider).isDefault, isTrue);
    });
  });

  group('hiding', () {
    test('takes a tab off the bar and reports where it went', () async {
      final container = _fresh();
      final hidden = await _controller(container).hide(NavDestination.map);

      expect(hidden, isTrue);
      final layout = container.read(navBarControllerProvider);
      expect(layout.shown, isNot(contains(NavDestination.map)));
      expect(layout.hidden, [NavDestination.map]);
      // The shell asks this to decide which tab to light up, and null is how it
      // learns the branch it is on has no tab any more.
      expect(layout.positionOf(NavDestination.map.branch), isNull);
    });

    test('refuses to hide Chats', () async {
      final container = _fresh();
      final hidden = await _controller(container).hide(NavDestination.chats);

      expect(hidden, isFalse,
          reason: 'it is the branch the app opens on and the one the system '
              'back gesture falls back to');
      expect(
        container.read(navBarControllerProvider).shown,
        contains(NavDestination.chats),
      );
    });

    test('refuses to go below two tabs', () async {
      final container = _fresh();
      final controller = _controller(container);
      expect(await controller.hide(NavDestination.map), isTrue);
      expect(await controller.hide(NavDestination.peers), isTrue);
      expect(await controller.hide(NavDestination.profile), isTrue);

      final layout = container.read(navBarControllerProvider);
      expect(layout.shown, hasLength(2));
      // One icon on a strip of glass is not a navigation bar, and there would
      // be no way back to the screen that could undo it.
      expect(await controller.hide(NavDestination.contacts), isFalse);
      expect(container.read(navBarControllerProvider).shown, hasLength(2));
    });

    test('putting one back appends it and restores the default', () async {
      final container = _fresh();
      final controller = _controller(container);
      await controller.hide(NavDestination.contacts);
      expect(container.read(navBarControllerProvider).shown, hasLength(4));

      await controller.show(NavDestination.contacts);
      final layout = container.read(navBarControllerProvider);
      expect(layout.shown, hasLength(5));
      expect(layout.shown.last, NavDestination.contacts,
          reason: 'it comes back at the end, where it can be dragged from');
      expect(layout.isDefault, isFalse, reason: 'the order changed');
    });

    test('showing something already there does nothing', () async {
      final container = _fresh();
      await _controller(container).show(NavDestination.map);
      expect(container.read(navBarControllerProvider).shown, hasLength(5));
    });
  });

  test('reset puts every tab back in the original order', () async {
    final container = _fresh();
    final controller = _controller(container);
    await controller.hide(NavDestination.map);
    await controller.reorder(2, 0);
    expect(container.read(navBarControllerProvider).isDefault, isFalse);

    await controller.reset();
    expect(container.read(navBarControllerProvider), NavBarLayout.initial);
    expect(container.read(navBarControllerProvider).isDefault, isTrue);
  });
}
