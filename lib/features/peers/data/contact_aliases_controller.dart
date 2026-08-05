import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Ceiling on a local alias. Same order as a nickname — this is a name, not a
/// note about somebody.
const int kContactAliasMaxLength = 40;

/// What *you* call a contact, keyed by pubkey hex.
///
/// Deliberately its own store rather than a field on `KnownPeer`. That record
/// is rebuilt from scratch by `upsert` on every inbound announcement and
/// rewritten wholesale by `touch` on every presence beacon — far more often
/// than anyone renames anyone. An alias living there would be one forgotten
/// `existing?.alias` away from being silently dropped the next time a field is
/// added to that constructor. Here that failure cannot happen: nothing on the
/// announcement path touches this box at all.
///
/// **Never transmitted.** It is what you call them, not what they call
/// themselves — a shared contact card still carries the peer's own broadcast
/// name, because a third party is being introduced to *them*, not to your
/// private label for them.
class ContactAliasesController extends Notifier<Map<String, String>> {
  Box<dynamic>? _box;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, String> build() {
    unawaited(_loading = _load());
    return const <String, String>{};
  }

  String? forPeer(String pubkeyHex) => state[pubkeyHex];

  /// Rename a contact locally. An empty alias clears it — going back to
  /// whatever they broadcast is the same act as never having renamed them.
  Future<bool> setAlias(String pubkeyHex, String alias) async {
    final trimmed = alias.trim();
    if (trimmed.length > kContactAliasMaxLength) return false;
    if (trimmed.isEmpty) {
      await clearAlias(pubkeyHex);
      return true;
    }
    state = {...state, pubkeyHex: trimmed};
    try {
      await _box?.put(pubkeyHex, trimmed);
    } catch (e) {
      debugPrint('ContactAliases persist failed: $e');
    }
    return true;
  }

  Future<void> clearAlias(String pubkeyHex) async {
    if (!state.containsKey(pubkeyHex)) return;
    state = {...state}..remove(pubkeyHex);
    try {
      await _box?.delete(pubkeyHex);
    } catch (e) {
      debugPrint('ContactAliases clear failed: $e');
    }
  }

  /// Back to nothing — Emergency Wipe.
  Future<void> clear() async {
    state = const <String, String>{};
    try {
      await _box?.clear();
    } catch (e) {
      debugPrint('ContactAliases wipe failed: $e');
    }
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.contactAliases);
      _box = box;
      final loaded = <String, String>{};
      for (final key in box.keys) {
        if (key is! String) continue;
        final raw = box.get(key);
        if (raw is String && raw.isNotEmpty) loaded[key] = raw;
      }
      if (loaded.isNotEmpty) state = {...loaded, ...state};
    } catch (e) {
      debugPrint('ContactAliases load failed: $e');
    }
  }
}

final contactAliasesControllerProvider =
    NotifierProvider<ContactAliasesController, Map<String, String>>(
  ContactAliasesController.new,
);
