import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// One emoji label per contact, for telling a long list apart at a glance.
///
/// The same idea as the tags on saved notes, and the same restraint: one label
/// per person, not a set. Two labels on one contact is a filing system, and a
/// filing system is what this exists to be simpler than — 👨‍👩‍👧 for family,
/// 💼 for work, and the row of labels above the list turns a column of names
/// into shelves.
///
/// Distinct from folders, which are cuts of the *chat* list and can be built
/// from anything. This is a property of a person, so it follows them into
/// every list they appear in.
///
/// Local and never on the wire. What you have decided to call somebody is your
/// business, in exactly the way a contact alias is — and telling them would
/// turn a private note into a message.
class ContactTagsController extends Notifier<Map<String, String>> {
  static const _key = 'contacts.tags';

  Box<dynamic>? _box;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, String> build() {
    unawaited(_loading = _load());
    return const <String, String>{};
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      if (raw is Map) {
        final loaded = <String, String>{};
        raw.forEach((k, v) {
          if (k is String && v is String && v.isNotEmpty) loaded[k] = v;
        });
        if (loaded.isNotEmpty) state = loaded;
      }
    } catch (e) {
      debugPrint('ContactTags load failed: $e');
    }
  }

  String? tagFor(String peerId) => state[peerId];

  /// Every label in use, in order of first appearance — so the filter row does
  /// not reshuffle itself each time a contact is labelled.
  List<String> get tagsInUse {
    final seen = <String>{};
    for (final tag in state.values) {
      seen.add(tag);
    }
    return seen.toList(growable: false);
  }

  Future<void> setTag(String peerId, String? tag) async {
    final next = {...state};
    if (tag == null || tag.isEmpty) {
      if (!next.containsKey(peerId)) return;
      next.remove(peerId);
    } else {
      if (next[peerId] == tag) return;
      next[peerId] = tag;
    }
    state = next;
    await _persist();
  }

  /// A contact who is gone takes their label with them.
  Future<void> forget(String peerId) => setTag(peerId, null);

  Future<void> clear() async {
    if (state.isEmpty) return;
    state = const <String, String>{};
    await _persist();
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, state);
    } catch (e) {
      debugPrint('ContactTags persist failed: $e');
    }
  }
}

final contactTagsControllerProvider =
    NotifierProvider<ContactTagsController, Map<String, String>>(
  ContactTagsController.new,
);
