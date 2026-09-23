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
      final raw = _box?.get(storageKey);
      if (raw is! String) return;
      state = AirDropLane.values.asNameMap()[raw] ?? AirDropLane.auto;
    } catch (e) {
      debugPrint('AirDropLaneController load failed: $e');
    }
  }

  Future<void> set(AirDropLane lane) async {
    state = lane;
    await loaded;
    await _box?.put(storageKey, lane.name);
  }

  Future<void> reset() async {
    state = AirDropLane.auto;
    await loaded;
    await _box?.delete(storageKey);
  }
}

final airdropLaneProvider =
    NotifierProvider<AirDropLaneController, AirDropLane>(
  AirDropLaneController.new,
);
