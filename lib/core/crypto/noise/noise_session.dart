import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../identity_keys.dart';
import 'noise_cipher_state.dart';
import 'noise_handshake_state.dart';

/// High-level wrapper around the XX handshake.
///
/// The expected lifecycle is:
///
///   1. `NoiseSession.initiate(identity)` — local side that contacts a peer
///      first; or `NoiseSession.respond(identity)` — local side that accepts
///      an incoming connection.
///   2. Drive the handshake by feeding inbound bytes to [readHandshake] and
///      writing outbound bytes from [writeHandshake] until [established] is
///      true. The exact alternation is dictated by the pattern, see below.
///   3. After that, use [encrypt] / [decrypt] for every transport message.
///
/// XX message ordering (`I` = initiator, `R` = responder):
/// ```
///   I.writeHandshake() -> bytes1
///                                  bytes1 -> R.readHandshake()
///                                  R.writeHandshake() -> bytes2
///   bytes2 -> I.readHandshake()
///   I.writeHandshake() -> bytes3
///                                  bytes3 -> R.readHandshake()
///   established on both sides
/// ```
class NoiseSession {
  NoiseSession._(this._handshake);

  final NoiseHandshakeState _handshake;
  NoiseCipherState? _sendCs;
  NoiseCipherState? _recvCs;

  static Future<NoiseSession> initiate(IdentityKeys identity) async {
    final hs = await NoiseHandshakeState.initialize(
      isInitiator: true,
      localStatic: identity.asKeyPair(),
    );
    return NoiseSession._(hs);
  }

  static Future<NoiseSession> respond(IdentityKeys identity) async {
    final hs = await NoiseHandshakeState.initialize(
      isInitiator: false,
      localStatic: identity.asKeyPair(),
    );
    return NoiseSession._(hs);
  }

  bool get established => _handshake.handshakeFinished;

  /// X25519 public key of the remote peer after the handshake has authenticated
  /// it. Null while we don't know yet.
  Uint8List? get remoteStaticPublicKey => _handshake.remoteStaticPublicKey;

  /// BLAKE2s fingerprint of the remote peer's public key. Convenient for the
  /// UI verification screen. Null until known.
  Future<String?> remoteFingerprint() async {
    final pk = remoteStaticPublicKey;
    if (pk == null) return null;
    final digest = await Blake2s().hash(pk);
    return IdentityKeys.formatFingerprint(Uint8List.fromList(digest.bytes));
  }

  Future<Uint8List> writeHandshake([Uint8List? payload]) {
    return _handshake.writeMessage(payload);
  }

  Future<Uint8List> readHandshake(Uint8List message) async {
    final payload = await _handshake.readMessage(message);
    if (_handshake.handshakeFinished) {
      _sendCs = _handshake.sendCipherState;
      _recvCs = _handshake.receiveCipherState;
    }
    return payload;
  }

  /// Convenience: drive the loop without manual readMessage/writeMessage
  /// after writes also might finish the handshake on the writer side.
  void promoteIfFinished() {
    if (_handshake.handshakeFinished) {
      _sendCs ??= _handshake.sendCipherState;
      _recvCs ??= _handshake.receiveCipherState;
    }
  }

  Future<Uint8List> encrypt(Uint8List plaintext, {Uint8List? ad}) {
    if (_sendCs == null) {
      throw const NoiseException('encrypt() called before handshake completed');
    }
    return _sendCs!.encryptWithAd(ad ?? Uint8List(0), plaintext);
  }

  Future<Uint8List> decrypt(Uint8List ciphertext, {Uint8List? ad}) {
    if (_recvCs == null) {
      throw const NoiseException('decrypt() called before handshake completed');
    }
    return _recvCs!.decryptWithAd(ad ?? Uint8List(0), ciphertext);
  }

  /// Zero key material — call when the session is torn down or the user
  /// triggers emergency wipe.
  void destroy() {
    _sendCs?.clear();
    _recvCs?.clear();
    _sendCs = null;
    _recvCs = null;
  }
}
