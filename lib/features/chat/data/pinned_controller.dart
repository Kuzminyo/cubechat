import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// The message a chat currently has pinned.
@immutable
class PinnedMessage {
  const PinnedMessage({required this.wireId, required this.pinnedAt});

  /// Transport [Message.wireId] of the pinned message — the handle both sides
  /// share, so a pin travels between devices without needing local row ids.
  final String wireId;

  /// When the pin was applied on this device (ours, or the moment a peer's pin
  /// landed). Used to decide which of two pins wins.
  final DateTime pinnedAt;

  @override
  bool operator ==(Object other) =>
      other is PinnedMessage &&
      other.wireId == wireId &&
      other.pinnedAt == pinnedAt;

  @override
  int get hashCode => Object.hash(wireId, pinnedAt);
}

/// Pinned messages per chat, keyed the way the chat list keys chats: a peer's
/// pubkey-hex or a `#channel` name. Up to 20 pins are retained in chronological
/// order and the public provider value exposes the newest pin for compatibility.
///
/// Pins live in the encrypted settings box. They are conversation state rather
/// than a private preference, so [MessagingService] mirrors every change to the
/// other side and both people see the same carousel.
class PinnedController extends Notifier<Map<String, PinnedMessage>> {
  static const _key = 'pinned_messages';

  Box<dynamic>? _box;
  Future<void>? _loading;
  final Map<String, List<PinnedMessage>> _all = {};

  /// Completes once the persisted pins have been merged into [state]; tests
  /// await it.
  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, PinnedMessage> build() {
    unawaited(_loading = _load());
    return const <String, PinnedMessage>{};
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      if (raw is! Map) return;
      final loaded = <String, PinnedMessage>{};
      for (final entry in raw.entries) {
        final chatId = entry.key;
        if (chatId is! String) continue;
        final values =
            entry.value is List ? entry.value as List : [entry.value];
        final pins = values.map(_decodePin).whereType<PinnedMessage>().toList()
          ..sort((a, b) => a.pinnedAt.compareTo(b.pinnedAt));
        if (pins.isEmpty) continue;
        _all[chatId] = pins;
        loaded[chatId] = pins.last;
      }
      if (loaded.isNotEmpty) {
        // Merge under anything pinned while the box was still opening.
        state = {...loaded, ...state};
      }
    } catch (e) {
      debugPrint('PinnedController load failed: $e');
    }
  }

  PinnedMessage? pinnedIn(String chatId) => state[chatId];

  List<PinnedMessage> pinnedAllIn(String chatId) =>
      List.unmodifiable(_all[chatId] ?? const <PinnedMessage>[]);

  bool isPinned(String chatId, String wireId) =>
      _all[chatId]?.any((pin) => pin.wireId == wireId) ?? false;

  /// Adds another pin. Re-pinning the same message moves it to the front of
  /// the banner carousel without duplicating it.
  Future<void> pin(String chatId, String wireId, {DateTime? at}) async {
    final next = [...?_all[chatId]]
      ..removeWhere((pin) => pin.wireId == wireId)
      ..add(PinnedMessage(wireId: wireId, pinnedAt: at ?? DateTime.now()));
    if (next.length > 20) next.removeAt(0);
    _all[chatId] = next;
    state = {...state, chatId: next.last};
    await _persist();
  }

  /// Removes one named pin, or all pins in the conversation when no id is
  /// supplied. Old single-pin persisted data is accepted during migration.
  Future<void> unpin(String chatId, {String? wireId}) async {
    final current = _all[chatId];
    if (current == null || current.isEmpty) return;
    final next = wireId == null
        ? <PinnedMessage>[]
        : current.where((pin) => pin.wireId != wireId).toList();
    if (next.length == current.length) return;
    if (next.isEmpty) {
      _all.remove(chatId);
      state = {...state}..remove(chatId);
    } else {
      _all[chatId] = next;
      state = {...state, chatId: next.last};
    }
    await _persist();
  }

  /// Drop all of a chat's pins because the chat itself is gone.
  Future<void> forget(String chatId) => unpin(chatId);

  /// Used by Emergency Wipe.
  Future<void> clear() async {
    _all.clear();
    state = const <String, PinnedMessage>{};
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('PinnedController clear failed: $e');
    }
  }

  static PinnedMessage? _decodePin(dynamic value) {
    if (value is! Map) return null;
    final wireId = value['wireId'];
    final at = DateTime.tryParse((value['atIso'] as String?) ?? '');
    if (wireId is! String || at == null) return null;
    return PinnedMessage(wireId: wireId, pinnedAt: at);
  }

  Future<void> _persist() async {
    final box = _box;
    if (box == null) return; // not loaded yet; next change rewrites the lot
    try {
      await box.put(_key, {
        for (final e in _all.entries)
          e.key: [
            for (final pin in e.value)
              {
                'wireId': pin.wireId,
                'atIso': pin.pinnedAt.toIso8601String(),
              },
          ],
      });
    } catch (e) {
      debugPrint('PinnedController persist failed: $e');
    }
  }
}

final pinnedControllerProvider =
    NotifierProvider<PinnedController, Map<String, PinnedMessage>>(
  PinnedController.new,
);
