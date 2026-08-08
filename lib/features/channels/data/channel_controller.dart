import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/crypto/channel_crypto.dart';
import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/transport/inner_payload.dart';
import '../models/channel.dart';

/// The set of group channels the user has joined, keyed by normalised name.
///
/// Backed by an encrypted Hive box — a channel's key is a read/write
/// credential, so it lives at rest under the same AES cipher as chat history
/// and is erased by Emergency Wipe. Joining is purely local: deriving the key
/// makes you a member the moment a matching-key message arrives; there's no
/// server or invite round-trip.
class ChannelController extends Notifier<Map<String, Channel>> {
  Box<Map<dynamic, dynamic>>? _box;

  @override
  Map<String, Channel> build() {
    unawaited(_loadFromDisk());
    return <String, Channel>{};
  }

  Future<void> _loadFromDisk() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<Map<dynamic, dynamic>>(HiveBoxes.channels);
      _box = box;
      final loaded = <String, Channel>{};
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw == null) continue;
        try {
          final c = _decode(raw);
          loaded[c.name] = c;
        } catch (e) {
          debugPrint('skip corrupt channel "$key": $e');
        }
      }
      if (loaded.isNotEmpty) {
        state = {...loaded, ...state};
      }
    } catch (e, st) {
      debugPrint('Channels load failed: $e\n$st');
    }
  }

  /// Join (or re-key) a channel. [rawName] is normalised via
  /// [normalizeChannelName]; [password] may be empty for an open channel.
  /// Returns the joined [Channel]. Throws [ArgumentError] on an empty name.
  Future<Channel> join(String rawName, {String password = ''}) async {
    final name = normalizeChannelName(rawName);
    if (name.isEmpty) {
      throw ArgumentError('channel name is empty');
    }
    // Refuse a name we could never hand to anyone: a channel invite has to fit
    // one BLE frame, and the name is the only variable-width field in it.
    if (utf8.encode(name).length > ChannelInvite.maxNameBytes) {
      throw ArgumentError('channel name is too long');
    }
    final key = await ChannelCrypto.deriveKey(name, password);
    final tag = await ChannelCrypto.deriveTag(key);
    return _store(name, key, tag, hasPassword: password.isNotEmpty);
  }

  /// Join from an invitation: the key arrives directly, so there's no password
  /// to derive from. [Channel.hasPassword] is unknowable on this path (the key
  /// is opaque) and is recorded as false — it's cosmetic either way.
  Future<Channel> joinWithKey(String rawName, Uint8List key) async {
    final name = normalizeChannelName(rawName);
    if (name.isEmpty) {
      throw ArgumentError('channel name is empty');
    }
    if (key.length != ChannelCrypto.keyLen) {
      throw ArgumentError('channel key must be ${ChannelCrypto.keyLen} bytes');
    }
    final tag = await ChannelCrypto.deriveTag(key);
    // Invited, so somebody was here first — see [Channel.viaInvite].
    return _store(name, key, tag, hasPassword: false, viaInvite: true);
  }

  Future<Channel> _store(
    String name,
    Uint8List key,
    Uint8List tag, {
    required bool hasPassword,
    bool viaInvite = false,
  }) async {
    final channel = Channel(
      name: name,
      hasPassword: hasPassword,
      key: key,
      tag: tag,
      // Sticky: re-deriving a room you were invited to, by typing its name,
      // does not promote you to having founded it.
      viaInvite: state[name]?.viaInvite ?? viaInvite,
      // Survives a re-join: the rule belongs to the room, not to this act of
      // joining it.
      adminOnly: state[name]?.adminOnly ?? false,
      // Re-joining an existing channel keeps its original position in the
      // chat list rather than jumping it to the top.
      joinedAt: state[name]?.joinedAt ?? DateTime.now(),
    );
    state = {...state, name: channel};
    await _persist(channel);
    return channel;
  }

  /// Record the room's posting rule, as an admin sets it or as it arrives from
  /// one.
  Future<void> setAdminOnly(String name, bool value) async {
    final current = state[normalizeChannelName(name)];
    if (current == null || current.adminOnly == value) return;
    final next = Channel(
      name: current.name,
      hasPassword: current.hasPassword,
      key: current.key,
      tag: current.tag,
      joinedAt: current.joinedAt,
      viaInvite: current.viaInvite,
      adminOnly: value,
    );
    state = {...state, next.name: next};
    await _persist(next);
  }

  /// Leave a channel — forget its key. Existing message history for the
  /// channel stays in the message store until a `/clear` or wipe.
  Future<void> leave(String name) async {
    final normalized = normalizeChannelName(name);
    if (!state.containsKey(normalized)) return;
    state = {...state}..remove(normalized);
    try {
      await _box?.delete(normalized);
    } catch (e) {
      debugPrint('Channel delete($normalized) failed: $e');
    }
  }

  /// The joined channel whose public selector matches [tag], or null if we're
  /// not a member. Linear scan — the join list is tiny.
  Channel? channelForTag(Uint8List tag) {
    for (final c in state.values) {
      if (_bytesEqual(c.tag, tag)) return c;
    }
    return null;
  }

  Channel? byName(String name) => state[normalizeChannelName(name)];

  /// Forget every channel — used by Emergency Wipe.
  Future<void> clear() async {
    state = <String, Channel>{};
    try {
      await _box?.clear();
    } catch (e) {
      debugPrint('Channels box clear failed: $e');
    }
  }

  Future<void> _persist(Channel c) async {
    final box = _box;
    if (box == null) return;
    try {
      await box.put(c.name, _encode(c));
    } catch (e) {
      debugPrint('Channel persist(${c.name}) failed: $e');
    }
  }

  static Map<String, dynamic> _encode(Channel c) => {
        'name': c.name,
        'hasPassword': c.hasPassword,
        'keyHex': _hexOf(c.key),
        'tagHex': _hexOf(c.tag),
        'joinedAtIso': c.joinedAt.toIso8601String(),
        'viaInvite': c.viaInvite,
        'adminOnly': c.adminOnly,
      };

  static Channel _decode(Map<dynamic, dynamic> m) => Channel(
        name: m['name'] as String,
        hasPassword: (m['hasPassword'] as bool?) ?? false,
        key: _hexDecode(m['keyHex'] as String),
        tag: _hexDecode(m['tagHex'] as String),
        joinedAt: DateTime.tryParse((m['joinedAtIso'] as String?) ?? '') ??
            DateTime.now(),
        // Absent in history written before the field existed. False is the
        // right reading of "we do not know": it lets a room joined by name
        // before this build still claim an unclaimed admin seat, which is the
        // migration those rooms need.
        viaInvite: (m['viaInvite'] as bool?) ?? false,
        adminOnly: (m['adminOnly'] as bool?) ?? false,
      );

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _hexOf(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _hexDecode(String hex) {
    if (hex.length.isOdd) return Uint8List(0);
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

final channelControllerProvider =
    NotifierProvider<ChannelController, Map<String, Channel>>(
  ChannelController.new,
);
