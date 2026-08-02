import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/transport/inner_payload.dart';

/// Avatar thumbnails other people have sent us, keyed by pubkey hex.
///
/// Kept apart from the roster on purpose — see [HiveBoxes.peerAvatars]. The
/// bytes are only ever written after [store] has checked them against the
/// digest from the peer's *signed* announcement, so what is cached here is
/// always the picture that peer committed to, not merely the one that arrived.
class PeerAvatarsController extends Notifier<Map<String, Uint8List>> {
  Box<dynamic>? _box;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, Uint8List> build() {
    unawaited(_loading = _load());
    return const <String, Uint8List>{};
  }

  Uint8List? forPeer(String pubkeyHex) => state[pubkeyHex];

  /// True when we already hold the picture [hash] names, so an announcement
  /// carrying it needs no request. This is what stops a heartbeat from asking
  /// for the same avatar every time it arrives.
  Future<bool> holds(String pubkeyHex, Uint8List hash) async {
    final have = state[pubkeyHex];
    if (have == null) return false;
    return _sameBytes(await _digest(have), hash);
  }

  /// Cache [jpeg] for [pubkeyHex], but only if it really is the picture
  /// [expectedHash] names.
  ///
  /// The digest comes from the peer's signed announcement, which is why this
  /// check is worth anything: the bytes travel separately and may have been
  /// handed over by a relay, but the hash they must match cannot be forged
  /// without the peer's Ed25519 key. Returns false when they don't match, so
  /// the caller can log a substitution attempt rather than cache it.
  Future<bool> store(
    String pubkeyHex,
    Uint8List jpeg,
    Uint8List expectedHash,
  ) async {
    if (jpeg.isEmpty || jpeg.length > AvatarPayload.maxBytes) return false;
    if (!_sameBytes(await _digest(jpeg), expectedHash)) return false;
    state = {...state, pubkeyHex: jpeg};
    await _persist(pubkeyHex, jpeg);
    return true;
  }

  /// Drop a peer's picture — they cleared theirs, or we forgot them.
  Future<void> forget(String pubkeyHex) async {
    if (!state.containsKey(pubkeyHex)) return;
    state = {...state}..remove(pubkeyHex);
    try {
      await _box?.delete(pubkeyHex);
    } catch (e) {
      debugPrint('PeerAvatars forget failed: $e');
    }
  }

  /// Back to nothing — Emergency Wipe.
  Future<void> clear() async {
    state = const <String, Uint8List>{};
    try {
      await _box?.clear();
    } catch (e) {
      debugPrint('PeerAvatars clear failed: $e');
    }
  }

  Future<Uint8List> _digest(Uint8List bytes) async =>
      Uint8List.fromList((await Sha256().hash(bytes)).bytes);

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.peerAvatars);
      _box = box;
      final loaded = <String, Uint8List>{};
      for (final key in box.keys) {
        if (key is! String) continue;
        final raw = box.get(key);
        if (raw is Uint8List && raw.isNotEmpty) {
          loaded[key] = raw;
        } else if (raw is List<int> && raw.isNotEmpty) {
          // Hive can hand back a plain List<int> depending on how it was written.
          loaded[key] = Uint8List.fromList(raw);
        }
      }
      if (loaded.isNotEmpty) state = {...loaded, ...state};
    } catch (e) {
      debugPrint('PeerAvatars load failed: $e');
    }
  }

  Future<void> _persist(String pubkeyHex, Uint8List jpeg) async {
    try {
      await _box?.put(pubkeyHex, jpeg);
    } catch (e) {
      debugPrint('PeerAvatars persist failed: $e');
    }
  }
}

final peerAvatarsControllerProvider =
    NotifierProvider<PeerAvatarsController, Map<String, Uint8List>>(
  PeerAvatarsController.new,
);
