import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// The five destinations, in the order the router declares them.
///
/// The *index* is the contract: `StatefulShellRoute` matches branches to tabs by
/// position, so these values are the router's branch indices and must not be
/// reordered here — reordering is what the user's own list is for. Adding a
/// destination means adding a branch at the same index in `app_router.dart`.
enum NavDestination {
  chats(0),
  contacts(1),
  peers(2),
  map(3),
  profile(4);

  const NavDestination(this.branch);

  /// Index of this destination's branch in the router.
  final int branch;

  static NavDestination? byBranch(int branch) {
    for (final d in NavDestination.values) {
      if (d.branch == branch) return d;
    }
    return null;
  }

  static NavDestination? byName(String name) {
    for (final d in NavDestination.values) {
      if (d.name == name) return d;
    }
    return null;
  }
}

/// Which tabs are on the bar and in what order.
///
/// Two rules, and both are about not stranding somebody:
///
///  * **Chats is always present.** It is the branch the app opens on and the one
///    the system back gesture falls back to (see the `PopScope` in `AppShell`);
///    a bar without it leaves back-out-of-a-tab pointing at a screen that is not
///    on the bar.
///  * **At least two tabs.** One tab is not a navigation bar, it is a strip of
///    glass with a single icon on it, and there would be no way to reach this
///    screen again to undo it.
///
/// The order drives the strip of branches as well as the bar — see
/// `BranchContainer`. If it drove only the bar, dragging sideways would walk the
/// router's order while the icons said something else, and the two would
/// disagree about which screen is "next".
class NavBarLayout {
  const NavBarLayout(this.shown);

  /// Visible destinations, left to right. Never empty, always contains
  /// [NavDestination.chats].
  final List<NavDestination> shown;

  static const NavBarLayout initial = NavBarLayout(NavDestination.values);

  /// The ones the user has put away, in enum order so the list is stable.
  List<NavDestination> get hidden => [
        for (final d in NavDestination.values)
          if (!shown.contains(d)) d,
      ];

  /// Router branch indices, in display order — what the shell needs.
  List<int> get branches => [for (final d in shown) d.branch];

  /// Where [branch] sits on the bar, or null when it is hidden.
  ///
  /// Null is a real case, not a defect: hiding the tab you are standing on is
  /// allowed, and the shell answers it by moving you to the first tab rather
  /// than by refusing the edit.
  int? positionOf(int branch) {
    final index = branches.indexOf(branch);
    return index < 0 ? null : index;
  }

  bool get isDefault => listEquals(shown, NavDestination.values);

  @override
  bool operator ==(Object other) =>
      other is NavBarLayout && listEquals(shown, other.shown);

  @override
  int get hashCode => Object.hashAll(shown);
}

class NavBarController extends Notifier<NavBarLayout> {
  static const _key = 'app.nav_bar_order';

  /// A bar this short stops being navigation.
  static const int minimumTabs = 2;

  Box<dynamic>? _box;

  @override
  NavBarLayout build() {
    unawaited(_load());
    return NavBarLayout.initial;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider.openEncryptedBox<dynamic>(
        HiveBoxes.settings,
      );
      _box = box;
      final saved = box.get(_key);
      if (saved is! List) return;
      final restored = <NavDestination>[
        for (final name in saved)
          if (name is String && NavDestination.byName(name) != null)
            NavDestination.byName(name)!,
      ];
      final layout = _sanitise(restored);
      if (layout != null) state = layout;
    } catch (e) {
      debugPrint('NavBar load failed: $e');
    }
  }

  /// Apply the two rules to a candidate list, or answer null if it is nonsense.
  ///
  /// Runs on the way *in* as well as on every edit: the stored list survives an
  /// upgrade that adds or removes a destination, and a list saved by an older
  /// build must not be able to produce a bar with one icon on it.
  NavBarLayout? _sanitise(List<NavDestination> candidate) {
    final unique = <NavDestination>[];
    for (final d in candidate) {
      if (!unique.contains(d)) unique.add(d);
    }
    if (!unique.contains(NavDestination.chats)) {
      unique.insert(0, NavDestination.chats);
    }
    if (unique.length < minimumTabs) return null;
    return NavBarLayout(List.unmodifiable(unique));
  }

  Future<void> _save(NavBarLayout layout) async {
    state = layout;
    try {
      await _box?.put(_key, [for (final d in layout.shown) d.name]);
    } catch (e) {
      debugPrint('NavBar persist failed: $e');
    }
  }

  /// Move the tab at [from] to [to] within the visible list.
  Future<void> reorder(int from, int to) async {
    final next = [...state.shown];
    if (from < 0 || from >= next.length) return;
    final moved = next.removeAt(from);
    next.insert(to.clamp(0, next.length), moved);
    final layout = _sanitise(next);
    if (layout != null) await _save(layout);
  }

  /// Take [destination] off the bar. Refused for Chats, and refused when it
  /// would leave fewer than [minimumTabs].
  Future<bool> hide(NavDestination destination) async {
    if (destination == NavDestination.chats) return false;
    if (state.shown.length <= minimumTabs) return false;
    final next = [...state.shown]..remove(destination);
    final layout = _sanitise(next);
    if (layout == null) return false;
    await _save(layout);
    return true;
  }

  /// Put [destination] back, at the end of the bar.
  Future<void> show(NavDestination destination) async {
    if (state.shown.contains(destination)) return;
    final layout = _sanitise([...state.shown, destination]);
    if (layout != null) await _save(layout);
  }

  Future<void> reset() => _save(NavBarLayout.initial);
}

final navBarControllerProvider =
    NotifierProvider<NavBarController, NavBarLayout>(NavBarController.new);
