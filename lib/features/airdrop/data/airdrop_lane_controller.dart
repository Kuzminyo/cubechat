import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Which radio a send goes out on. The sender's setting decides — the
/// receiver has no say, it just answers whatever shows up. `wifi` means
/// "fail rather than crawl over Bluetooth": no fallback, no silent slow path.
enum AirDropLane { auto, bluetooth, wifi }

/// "Channel: Auto / Bluetooth / Wi-Fi" — a small persisted preference, same
/// shape as [AirDropReceiveController] next to it.
class AirDropLaneController extends Notifier<AirDropLane> {
  static const storageKey = 'airdrop.lane';

  Box<dynamic>? _box;
  Future<void>? _loading;

  // set()/reset() write `state` synchronously, then await the box before
  // persisting — but _load() is still in flight at that point (it awaits the
  // box open too) and used to finish afterwards with its own `state = ...`
  // from whatever was already on disk, clobbering the caller's choice in
  // memory even though the *persisted* value came out right. Concretely:
  // `reset()` called on a never-before-read provider (exactly what the wipe
  // does) left `state == wifi` while the key was deleted. Once set()/reset()
  // has run, _load() must never touch `state` again.
  bool _touched = false;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  AirDropLane build() {
    unawaited(_loading = _load());
    return AirDropLane.auto;
  }

  Future<void> _load() async {
    try {
      _box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      if (_touched) return;
      final raw = _box?.get(storageKey);
      if (raw is! String) return;
      state = AirDropLane.values.asNameMap()[raw] ?? AirDropLane.auto;
    } catch (e) {
      debugPrint('AirDropLaneController load failed: $e');
    }
  }

  Future<void> set(AirDropLane lane) async {
    _touched = true;
    state = lane;
    await loaded;
    await _box?.put(storageKey, lane.name);
  }

  Future<void> reset() async {
    _touched = true;
    state = AirDropLane.auto;
    await loaded;
    await _box?.delete(storageKey);
  }
}

final airdropLaneProvider =
    NotifierProvider<AirDropLaneController, AirDropLane>(
  AirDropLaneController.new,
);
