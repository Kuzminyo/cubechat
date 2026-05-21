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

  /// Returns the cipher, generating a fresh key on first run.
  Future<HiveAesCipher> load() async {
    if (_cached != null) return _cached!;
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
    try {
      await _storage.delete(key: _keyName);
    } catch (_) {}
  }

  /// Opens (or creates) a Hive box encrypted under our cipher. If a box
  /// of the same name exists on disk but can't be decrypted - most
  /// likely a leftover from a build that wrote unencrypted boxes - we
  /// delete and reopen so the user lands on a clean encrypted box rather
  /// than an opaque error.
  Future<Box<T>> openEncryptedBox<T>(String name) async {
    final cipher = await load();
    try {
      return await Hive.openBox<T>(name, encryptionCipher: cipher);
    } catch (e, st) {
      debugPrint('Hive openBox($name) failed under cipher: $e\n$st - '
          'deleting and retrying (legacy unencrypted box?)');
      try {
        if (Hive.isBoxOpen(name)) {
          await Hive.box<dynamic>(name).close();
        }
      } catch (_) {}
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
