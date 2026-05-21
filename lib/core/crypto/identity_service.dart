import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
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
  static const _signSeedKey = 'cubechat.identity.signseed';

  final FlutterSecureStorage _storage;
  final _x25519 = X25519();
  final _ed25519 = Ed25519();

  IdentityKeys? _cached;

  /// Returns the cached identity, loading or generating one if needed.
  /// Migrates legacy identities (X25519 only) by minting a fresh Ed25519
  /// keypair alongside.
  Future<IdentityKeys> load() async {
    if (_cached != null) return _cached!;

    // Reading Keystore-backed secure storage can throw on some devices —
    // most notably after an OS update (e.g. One UI 8.5) or a backup/restore
    // invalidates the underlying key, surfacing as
    // `BadPaddingException: BAD_DECRYPT`. An unhandled throw here used to
    // crash the whole handshake. Treat any read failure as "no stored
    // identity": reset the corrupt store and mint a fresh keypair so the
    // app keeps working (the user appears as a new identity, which is the
    // unavoidable cost of the old private key being unrecoverable).
    String? hexX;
    String? hexEd;
    try {
      hexX = await _storage.read(key: _privateKeyKey);
      hexEd = await _storage.read(key: _signSeedKey);
    } catch (e, st) {
      debugPrint('IdentityService: secure read failed ($e) — '
          'resetting identity store\n$st');
      await _resetSecureStore();
      hexX = null;
      hexEd = null;
    }

    final Uint8List xPriv;
    if (hexX != null && hexX.length == 64) {
      xPriv = _hexDecode(hexX);
    } else {
      final pair = await _x25519.newKeyPair();
      xPriv = Uint8List.fromList(await pair.extractPrivateKeyBytes());
      await _tryWrite(_privateKeyKey, _hexEncode(xPriv));
    }

    Uint8List edSeed;
    if (hexEd != null && hexEd.length == 64) {
      edSeed = _hexDecode(hexEd);
    } else {
      // Migrate pre-Ed25519 identities: mint a fresh sign-keypair and
      // persist it. The X25519 pubkey (and therefore the user's
      // pubkey-hex chat identity) stays the same — only the signing
      // material is new.
      final pair = await _ed25519.newKeyPair();
      edSeed = Uint8List.fromList(await pair.extractPrivateKeyBytes());
      await _tryWrite(_signSeedKey, _hexEncode(edSeed));
    }

    _cached = await _materialize(xPriv, edSeed);
    return _cached!;
  }

  /// Clears the (possibly corrupt) secure store so fresh keys can be written.
  /// deleteAll recreates the master key on the next access; falls back to
  /// per-key deletes if even that throws.
  Future<void> _resetSecureStore() async {
    try {
      await _storage.deleteAll();
      return;
    } catch (e) {
      debugPrint('IdentityService: deleteAll failed ($e) — trying per-key');
    }
    for (final k in [_privateKeyKey, _signSeedKey]) {
      try {
        await _storage.delete(key: k);
      } catch (_) {}
    }
  }

  /// Persist a value, swallowing storage failures. If the keystore is so
  /// broken even writes throw, we run with an in-memory-only identity for
  /// this session rather than crashing (it'll be re-minted next launch).
  Future<void> _tryWrite(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      debugPrint('IdentityService: secure write($key) failed ($e) — '
          'identity is in-memory only this session');
    }
  }

  /// Erases the persistent private key — backs the "Emergency wipe" feature.
  /// After this, the next `load()` call will mint a new identity.
  Future<void> wipe() async {
    _cached = null;
    for (final k in [_privateKeyKey, _signSeedKey]) {
      try {
        await _storage.delete(key: k);
      } catch (_) {}
    }
  }

  Future<IdentityKeys> _materialize(Uint8List xPriv, Uint8List edSeed) async {
    final xPair = await _x25519.newKeyPairFromSeed(xPriv);
    final xPub = await xPair.extractPublicKey();
    final edPair = await _ed25519.newKeyPairFromSeed(edSeed);
    final edPub = await edPair.extractPublicKey();
    return IdentityKeys(
      publicKey: Uint8List.fromList(xPub.bytes),
      privateKey: xPriv,
      signPublicKey: Uint8List.fromList(edPub.bytes),
      signPrivateKey: edSeed,
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
