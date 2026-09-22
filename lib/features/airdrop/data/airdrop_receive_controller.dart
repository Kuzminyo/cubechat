import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../domain/airdrop_rules.dart';
import 'airdrop_clock.dart';

/// "Receive from: Contacts / Everyone for 10 min".
@immutable
class AirDropReceive {
  const AirDropReceive({this.everyoneUntil});

  /// Null means contacts only.
  final DateTime? everyoneUntil;

  bool everyoneAt(DateTime now) {
    final until = everyoneUntil;
    return until != null && now.isBefore(until);
  }
}

/// While "everyone" is on, this phone is also visible to strangers — the XX
/// handshake is answered even with "Discoverable nearby" off in the profile
/// (see `MessagingService._discoverableNow`). It switches itself off, so
/// nobody is left visible by forgetting.
class AirDropReceiveController extends Notifier<AirDropReceive> {
  static const storageKey = 'airdrop.everyoneUntil';

  Box<dynamic>? _box;
  Future<void>? _loading;
  Timer? _expiry;

  Future<void> get loaded => _loading ?? Future<void>.value();

  DateTime get _now => ref.read(airdropClockProvider)();

  @override
  AirDropReceive build() {
    ref.onDispose(() => _expiry?.cancel());
    unawaited(_loading = _load());
    return const AirDropReceive();
  }

  Future<void> _load() async {
    try {
      _box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      final raw = _box?.get(storageKey);
      if (raw is! int) return;
      final until = DateTime.fromMillisecondsSinceEpoch(raw);
      if (!until.isAfter(_now)) {
        await _box?.delete(storageKey);
        return;
      }
      state = AirDropReceive(everyoneUntil: until);
      _arm(until);
    } catch (e) {
      debugPrint('AirDropReceiveController load failed: $e');
    }
  }

  Future<void> openToEveryone() async {
    final until = _now.add(AirDropRules.everyoneFor);
    state = AirDropReceive(everyoneUntil: until);
    _arm(until);
    await loaded;
    await _box?.put(storageKey, until.millisecondsSinceEpoch);
  }

  Future<void> contactsOnly() async {
    _expiry?.cancel();
    _expiry = null;
    state = const AirDropReceive();
    await loaded;
    await _box?.delete(storageKey);
  }

  Future<void> reset() => contactsOnly();

  void _arm(DateTime until) {
    _expiry?.cancel();
    final left = until.difference(_now);
    _expiry = Timer(
      left.isNegative ? Duration.zero : left,
      () => unawaited(contactsOnly()),
    );
  }
}

final airdropReceiveProvider =
    NotifierProvider<AirDropReceiveController, AirDropReceive>(
  AirDropReceiveController.new,
);
