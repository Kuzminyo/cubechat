import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// People this phone was told to forget, so that forgetting them sticks.
///
/// Removing a contact took the roster entry and everything attached to it, and
/// then the next thing they broadcast put them straight back: an announcement
/// over the mesh, a presence beacon, a handshake — any of them registers a
/// known peer, and none of them had any way of knowing the person had been
/// removed on purpose. So a deleted contact reappeared in Nearby and in
/// Contacts within seconds, which is what "I removed them and their phone is
/// still there" was.
///
/// A tombstone rather than a block: it says "do not re-create this entry from
/// something they broadcast", not "refuse this person". Being findable is not
/// the same as being a contact, and the difference is the whole point of the
/// removal.
///
/// It clears itself the moment they actually write — see
/// [MessagingService]. Mail is never worth losing to a preference, and a
/// message is a deliberate act by a person, not a radio doing its rounds. Re-
/// adding them from a card clears it too.
class RemovedContactsController extends Notifier<Set<String>> {
  static const _key = 'removed_contacts';

  Box<dynamic>? _box;

  @override
  Set<String> build() {
    unawaited(_load());
    return const <String>{};
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      if (raw is List) {
        final loaded = raw.whereType<String>().toSet();
        // Merged under what is already here, never assigned over it: this
        // lands at an unknown moment after an encrypted box has opened, and a
        // contact removed before it finished would otherwise be un-removed by
        // it. The same trap as `HiddenChatsController`, which had it.
        if (loaded.isNotEmpty) state = {...loaded, ...state};
      }
    } catch (e) {
      debugPrint('RemovedContacts load failed: $e');
    }
  }

  bool contains(String pubkeyHex) => state.contains(pubkeyHex);

  Future<void> remember(String pubkeyHex) async {
    if (state.contains(pubkeyHex)) return;
    state = {...state, pubkeyHex};
    await _persist();
  }

  /// They are a contact again — because they wrote, or because their card was
  /// scanned. Either way the tombstone has done its job and must go, or the
  /// roster entry they need could never be created.
  Future<void> restore(String pubkeyHex) async {
    if (!state.contains(pubkeyHex)) return;
    state = {...state}..remove(pubkeyHex);
    await _persist();
  }

  /// Used by Emergency Wipe.
  Future<void> clear() async {
    state = const <String>{};
    await _persist();
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, state.toList());
    } catch (e) {
      debugPrint('RemovedContacts persist failed: $e');
    }
  }
}

final removedContactsControllerProvider =
    NotifierProvider<RemovedContactsController, Set<String>>(
  RemovedContactsController.new,
);
