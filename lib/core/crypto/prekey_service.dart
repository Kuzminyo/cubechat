import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../storage/hive_cipher.dart';
import 'identity_service.dart';
import 'prekey_store.dart';

/// Owns this device's signed prekey for forward-secret messaging and
/// persists its private half so it survives restarts.
///
/// Forward secrecy comes from the per-message ephemeral key the *sender*
/// generates; the signed prekey is the long-lived recipient-side half the
/// sender mixes in. Peers learn our signed-prekey *public* value from our
/// signed announcement and encrypt to it; therefore the private half MUST be
/// stable across launches — regenerating it would orphan every in-flight
/// message addressed to the old one. Hence persistence in an encrypted Hive
/// box (same cipher as chat history).
///
/// v1 keeps a single signed prekey (no rotation, no one-time prekeys yet).
/// X3DH still achieves forward secrecy via the sender's ephemeral; one-time
/// prekeys (KCI resistance) are a future enhancement.
class PrekeyService {
  PrekeyService(this._ref);

  final Ref _ref;
  static const _boxName = 'cubechat.prekeys';

  PrekeyStore? _store;
  Box<dynamic>? _box;
  Future<void>? _inFlight;

  /// True once a signed prekey is loaded/minted and ready to advertise.
  bool get isReady => _store?.currentSignedPrekey != null;

  Uint8List get signedPrekeyPub => _store!.currentSignedPrekey!.pub;
  Uint8List get signedPrekeySig => _store!.currentSignedPrekey!.signature;
  int get signedPrekeyId => _store!.currentSignedPrekey!.id;

  /// The X25519 key pair behind the current signed prekey — used on the
  /// receive side of X3DH.
  SimpleKeyPairData get signedPrekeyKeyPair =>
      _store!.currentSignedPrekey!.keyPair;

  /// Loads the persisted signed prekey, or mints + signs + persists a fresh
  /// one on first run. Idempotent — and single-flight, because `isReady` only
  /// flips after several awaits. Two concurrent callers (the MessagingService
  /// constructor and the first inbound forward-secret frame) would otherwise
  /// each mint and persist a *different* signed prekey; whichever lost the race
  /// would still be advertised to peers, and every message sent to it would
  /// fail to decrypt.
  Future<void> ensureInitialized() {
    if (isReady) return Future<void>.value();
    return _inFlight ??= _initialize().whenComplete(() => _inFlight = null);
  }

  Future<void> _initialize() async {
    final identity = await _ref.read(identityProvider.future);
    final store = PrekeyStore(
      identityKeyPair: identity.asKeyPair(),
      identityPub: identity.publicKey,
      signKeyPair: identity.asSignKeyPair(),
    );
    _store = store;

    try {
      _box = await hiveCipherProvider.openEncryptedBox<dynamic>(_boxName);
      final id = _box!.get('spkId') as int?;
      final priv = _bytes(_box!.get('spkPriv'));
      final pub = _bytes(_box!.get('spkPub'));
      final sig = _bytes(_box!.get('spkSig'));
      if (id != null && priv != null && pub != null && sig != null) {
        store.restoreSignedPrekey(id: id, priv: priv, pub: pub, sig: sig);
        debugPrint('PrekeyService: restored signed prekey #$id');
        return;
      }
    } catch (e) {
      debugPrint('PrekeyService: load failed ($e) — minting fresh');
    }

    // First run (or unreadable): mint, sign, persist.
    await store.rotateSignedPrekey();
    await _persist();
    debugPrint('PrekeyService: minted fresh signed prekey #${signedPrekeyId}');
  }

  Future<void> _persist() async {
    final box = _box;
    final spk = _store?.currentSignedPrekey;
    if (box == null || spk == null) return;
    try {
      final priv =
          Uint8List.fromList(await spk.keyPair.extractPrivateKeyBytes());
      await box.putAll({
        'spkId': spk.id,
        'spkPriv': priv,
        'spkPub': spk.pub,
        'spkSig': spk.signature,
      });
    } catch (e) {
      debugPrint('PrekeyService: persist failed ($e)');
    }
  }

  static Uint8List? _bytes(dynamic v) {
    if (v == null) return null;
    if (v is Uint8List) return v;
    if (v is List) return Uint8List.fromList(v.cast<int>());
    return null;
  }
}

final prekeyServiceProvider = Provider<PrekeyService>((ref) {
  return PrekeyService(ref);
});
