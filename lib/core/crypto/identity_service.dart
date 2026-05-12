import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'identity_keys.dart';

/// Generates the long-term X25519 identity on first run and persists the
/// private key in the platform secure store (Keychain on iOS, Keystore-backed
/// EncryptedSharedPreferences on Android).
///
/// The public key is rederived from the private key on every load — no need
/// to store it.
class IdentityService {
  IdentityService({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            );

  static const _privateKeyKey = 'cubechat.identity.priv';

  final FlutterSecureStorage _storage;
  final _x25519 = X25519();

  IdentityKeys? _cached;

  /// Returns the cached identity, loading or generating one if needed.
  Future<IdentityKeys> load() async {
    if (_cached != null) return _cached!;

    final hex = await _storage.read(key: _privateKeyKey);
    if (hex != null && hex.length == 64) {
      _cached = await _materialize(_hexDecode(hex));
      return _cached!;
    }

    // First run — mint a fresh key.
    final pair = await _x25519.newKeyPair();
    final priv = Uint8List.fromList(await pair.extractPrivateKeyBytes());
    await _storage.write(key: _privateKeyKey, value: _hexEncode(priv));
    _cached = await _materialize(priv);
    return _cached!;
  }

  /// Erases the persistent private key — backs the "Emergency wipe" feature.
  /// After this, the next `load()` call will mint a new identity.
  Future<void> wipe() async {
    _cached = null;
    await _storage.delete(key: _privateKeyKey);
  }

  Future<IdentityKeys> _materialize(Uint8List priv) async {
    final pair = await _x25519.newKeyPairFromSeed(priv);
    final pub = await pair.extractPublicKey();
    return IdentityKeys(
      publicKey: Uint8List.fromList(pub.bytes),
      privateKey: priv,
    );
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

final identityServiceProvider = Provider<IdentityService>((_) => IdentityService());

final identityProvider = FutureProvider<IdentityKeys>((ref) {
  return ref.watch(identityServiceProvider).load();
});

final identityFingerprintProvider = FutureProvider<String>((ref) async {
  final identity = await ref.watch(identityProvider.future);
  return identity.fingerprint();
});
