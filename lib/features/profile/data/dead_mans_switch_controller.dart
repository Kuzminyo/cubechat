import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Wipe the phone if nobody opens the app for long enough.
///
/// For the case the app lock cannot answer: not somebody holding the phone
/// while you are there, but the phone being somewhere you are not — lost,
/// taken, or left behind. Everything else in this app protects messages in
/// motion; this protects the ones sitting still on a device that has stopped
/// being yours.
///
/// Off by default and deliberately hard to arm by accident. It cannot ask
/// before it fires — the whole premise is that nobody is there to ask — so all
/// the safety has to live at the moment it is switched on.
@immutable
class DeadMansSwitch {
  const DeadMansSwitch({this.days = 0, this.lastOpened});

  /// Days of silence before the wipe. Zero is off.
  final int days;

  /// When the app was last opened. Null until the first launch records one.
  final DateTime? lastOpened;

  bool get enabled => days > 0;

  /// Whether [now] is past the deadline. False when off, and false until a
  /// first launch has been recorded — a switch that fires before it has ever
  /// seen the app opened would wipe on the install that armed it.
  bool hasExpired(DateTime now) {
    if (!enabled) return false;
    final last = lastOpened;
    if (last == null) return false;
    return now.difference(last) >= Duration(days: days);
  }

  DeadMansSwitch copyWith({int? days, DateTime? lastOpened}) => DeadMansSwitch(
        days: days ?? this.days,
        lastOpened: lastOpened ?? this.lastOpened,
      );
}

class DeadMansSwitchController extends Notifier<DeadMansSwitch> {
  static const _daysKey = 'deadman.days';
  static const _seenKey = 'deadman.last_opened';

  /// What may be chosen. A week is the floor on purpose: anything shorter and
  /// an ordinary holiday, a hospital stay or a flat battery costs somebody
  /// every message they have.
  static const List<int> choices = [0, 7, 14, 30, 90];

  Box<dynamic>? _box;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  DeadMansSwitch build() {
    unawaited(_loading = _load());
    return const DeadMansSwitch();
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider.openEncryptedBox<dynamic>(
        HiveBoxes.settings,
      );
      _box = box;
      final days = box.get(_daysKey) as int? ?? 0;
      final seenMs = box.get(_seenKey) as int?;
      state = DeadMansSwitch(
        days: days,
        lastOpened: seenMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(seenMs),
      );
    } catch (e) {
      debugPrint('DeadMansSwitch load failed: $e');
    }
  }

  Future<void> setDays(int days) async {
    // Arming it also starts its clock. Without this the first check would
    // measure from whenever the app last happened to be opened, which could
    // already be past the deadline the user just chose.
    final now = DateTime.now();
    state = DeadMansSwitch(days: days, lastOpened: now);
    await _put(_daysKey, days);
    await _put(_seenKey, now.millisecondsSinceEpoch);
  }

  /// The app is being looked at. Called on every launch and every return to
  /// the foreground.
  Future<void> noteOpened() async {
    final now = DateTime.now();
    state = state.copyWith(lastOpened: now);
    await _put(_seenKey, now.millisecondsSinceEpoch);
  }

  Future<void> _put(String key, Object? value) async {
    try {
      await _box?.put(key, value);
    } catch (e) {
      debugPrint('DeadMansSwitch persist $key failed: $e');
    }
  }
}

final deadMansSwitchProvider =
    NotifierProvider<DeadMansSwitchController, DeadMansSwitch>(
  DeadMansSwitchController.new,
);
