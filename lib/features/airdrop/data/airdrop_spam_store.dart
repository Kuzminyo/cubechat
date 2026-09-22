import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../domain/airdrop_spam_guard.dart';

/// One [SpamRecord] per stranger, kept across restarts so closing the app is
/// not a way out of a ban.
class AirDropSpamStore extends Notifier<Map<String, SpamRecord>> {
  static const storageKey = 'airdrop.spam.v1';

  Box<dynamic>? _box;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, SpamRecord> build() {
    unawaited(_loading = _load());
    return const {};
  }

  Future<void> _load() async {
    try {
      _box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      final raw = _box?.get(storageKey);
      if (raw is! Map) return;
      final restored = <String, SpamRecord>{};
      raw.forEach((key, value) {
        if (key is! String || value is! Map) return;
        final record = SpamRecord.fromJson(value);
        if (record != null) restored[key] = record;
      });
      state = {...restored, ...state};
    } catch (e) {
      debugPrint('AirDropSpamStore load failed: $e');
    }
  }

  SpamRecord? recordFor(String peerHex) => state[peerHex];

  void put(String peerHex, SpamRecord record) {
    state = {...state, peerHex: record};
    unawaited(save(state));
  }

  void remove(String peerHex) {
    if (!state.containsKey(peerHex)) return;
    state = {...state}..remove(peerHex);
    unawaited(save(state));
  }

  Future<void> clear() async {
    state = const {};
    await save(state);
  }

  @protected
  Future<void> save(Map<String, SpamRecord> records) async {
    if (_box == null) await loaded;
    await _box?.put(storageKey, {
      for (final e in records.entries) e.key: e.value.toJson(),
    });
  }
}

final airdropSpamProvider =
    NotifierProvider<AirDropSpamStore, Map<String, SpamRecord>>(
  AirDropSpamStore.new,
);
