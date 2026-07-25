import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';

/// Lazily-loaded HiveAesCipher backed by a 32-byte key in the platform
/// secure store. First call mints a fresh key; every subsequent call
/// returns the same one, so Hive can decrypt boxes written earlier.
///
/// Why secure storage and not a derived key: identity-key wipe must not
/// also wipe history (or vice versa), so the two live under their own
/// keychain entries. The cipher key is data-encryption-only - it never
/// signs anything and is independent of the X25519 / Ed25519 identity.
class HiveCipherProvider {
  HiveCipherProvider({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  static const _keyName = 'cubechat.hive.aeskey';
  static const _keyLen = 32;
  static final _rand = Random.secure();

  final FlutterSecureStorage _storage;
  HiveAesCipher? _cached;
  Future<HiveAesCipher>? _inFlight;

  /// Returns the cipher, generating a fresh key on first run.
  ///
  /// Single-flight, and it has to be: every controller opens its encrypted box
  /// during startup, so half a dozen callers hit this at once. Checking
  /// `_cached` and *then* awaiting the secure store let all of them miss the
  /// empty cache, mint a **different** random key, and open their box under it.
  /// Only the last key reached secure storage, so on the next launch every box
  /// written under one of the others failed to decrypt and was deleted and
  /// recreated — the peer roster, chat history, channels and prekeys silently
  /// reset once per install.
  Future<HiveAesCipher> load() {
    final cached = _cached;
    if (cached != null) return Future<HiveAesCipher>.value(cached);
    return _inFlight ??= _load();
  }

  Future<HiveAesCipher> _load() async {
    try {
      return await _loadUncached();
    } finally {
      _inFlight = null;
    }
  }

  Future<HiveAesCipher> _loadUncached() async {
    // Same Keystore-corruption hazard as IdentityService: a read can throw
    // BadPaddingException after an OS update invalidates the master key.
    // Treat a read failure as "no key yet" — mint a fresh one. The old
    // encrypted boxes become unreadable, but openEncryptedBox already
    // deletes-and-recreates a box it can't decrypt, so chat history just
    // resets rather than crashing.
    String? existing;
    try {
      existing = await _storage.read(key: _keyName);
    } catch (e) {
      debugPrint('Hive cipher: secure read failed ($e) — resetting key');
      try {
        await _storage.deleteAll();
      } catch (_) {
        try {
          await _storage.delete(key: _keyName);
        } catch (_) {}
      }
      existing = null;
    }
    Uint8List keyBytes;
    if (existing != null && existing.length == _keyLen * 2) {
      keyBytes = _hexDecode(existing);
    } else {
      keyBytes = Uint8List(_keyLen);
      for (var i = 0; i < _keyLen; i++) {
        keyBytes[i] = _rand.nextInt(256);
      }
      try {
        await _storage.write(key: _keyName, value: _hexEncode(keyBytes));
        debugPrint('Hive cipher: minted fresh 32-byte AES key');
      } catch (e) {
        debugPrint('Hive cipher: secure write failed ($e) — '
            'history encryption is session-only this launch');
      }
    }
    _cached = HiveAesCipher(keyBytes);
    return _cached!;
  }

  /// Forgets the in-memory cipher and erases the persisted key - used by
  /// Emergency Wipe alongside the identity / box deletion. Any encrypted
  /// box files left on disk become unrecoverable.
  Future<void> wipe() async {
    _cached = null;
    _inFlight = null;
    try {
      await _storage.delete(key: _keyName);
    } catch (_) {}
  }

  /// One in-flight open per box name, so concurrent openers of the same box
  /// share a single [Hive.openBox] instead of racing into it.
  final Map<String, Future<void>> _opening = {};

  /// Opens (or creates) a Hive box encrypted under our cipher. If a box
  /// of the same name exists on disk but can't be decrypted - most
  /// likely a leftover from a build that wrote unencrypted boxes - we
  /// delete and reopen so the user lands on a clean encrypted box rather
  /// than an opaque error.
  ///
  /// Single-flight per box name, for the same reason [load] is: at startup
  /// half a dozen controllers open the *same* `settings` box at once. Letting
  /// them all race into [Hive.openBox] meant a loser could hit the
  /// delete-and-retry path below, [Hive.deleteBoxFromDisk] the box the winner
  /// had already handed out, and leave every other holder with a dead handle —
  /// surfacing later as "Box has already been closed" on a write, and silently
  /// wiping that box's data (read markers, favourites, relay settings). Now the
  /// first caller opens it and the rest await that one open and reuse the live
  /// handle.
  Future<Box<T>> openEncryptedBox<T>(String name) async {
    // Already open (this call, or an earlier one, won) → reuse the live handle.
    if (Hive.isBoxOpen(name)) return _handle<T>(name);
    // Someone else is opening this exact box right now → wait for them, then
    // take the shared handle. Never open it a second time in parallel.
    final pending = _opening[name];
    if (pending != null) {
      await pending;
      return _handle<T>(name);
    }
    final future = _openFresh<T>(name);
    _opening[name] = future;
    try {
      return await future;
    } finally {
      _opening.remove(name);
    }
  }

  /// The live handle for an already-open box, tolerating a type-parameter
  /// mismatch by falling back to the shared dynamic handle.
  Box<T> _handle<T>(String name) {
    try {
      return Hive.box<T>(name);
    } catch (_) {
      return Hive.box<dynamic>(name) as Box<T>;
    }
  }

  Future<Box<T>> _openFresh<T>(String name) async {
    final cipher = await load();
    try {
      return await Hive.openBox<T>(name, encryptionCipher: cipher);
    } catch (e, st) {
      final msg = e.toString();
      if (msg.contains('already open')) {
        // Opened out from under us despite the single-flight guard (e.g. by
        // code that opens Hive boxes directly). Reuse rather than destroy.
        return _handle<T>(name);
      }
      // Genuine open failure — most likely an undecryptable legacy
      // (unencrypted) box from a pre-encryption build. Delete + retry.
      debugPrint('Hive openBox($name) failed under cipher: $e\n$st - '
          'deleting and retrying (legacy unencrypted box?)');
      try {
        await Hive.deleteBoxFromDisk(name);
      } catch (_) {}
      return Hive.openBox<T>(name, encryptionCipher: cipher);
    }
  }

  static String _hexEncode(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _hexDecode(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

/// Singleton - controllers grab the same instance so they share the
/// in-memory cipher cache.
final hiveCipherProvider = HiveCipherProvider();
