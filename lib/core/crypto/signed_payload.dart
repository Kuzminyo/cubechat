import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Self-authenticating wrapper for SealedBox plaintexts.
///
/// Wire layout (lives *inside* a SealedBox ciphertext):
///
/// ```
///   [marker        : 1 byte  = 0xA1]
///   [sender_ed_pub : 32 bytes — Ed25519 verifying key]
///   [signature     : 64 bytes — Ed25519 over context || ed_pub || inner]
///   [inner         : N bytes — the actual InnerPayload (type tag + body)]
/// ```
///
/// `context` is computed by [contextBytes] from the [TransportEnvelope]'s
/// origin/dest/msgId. It binds the signature to a specific route so the
/// frame can't be replayed under a different envelope.
///
/// **Identity binding**: the receiver also holds (or is currently learning)
/// the mapping `originPubkeyHash → Ed25519 pubkey` from peer announcements.
/// On a strict path you cross-check the embedded ed_pub against that cache;
/// on a permissive path (used at first contact before any announcement) you
/// accept the message and let the next announcement RX confirm-or-revoke.
///
/// The marker byte 0xA1 is chosen so it can never collide with any
/// [InnerPayloadType] tag — the receiver tells signed vs. unsigned
/// payloads apart by inspecting position 0.
class SignedPayload {
  SignedPayload._();

  static const int markerByte = 0xA1;
  static const int pubLen = 32;
  static const int sigLen = 64;
  static const int headerLen = 1 + pubLen + sigLen;

  static final _ed25519 = Ed25519();

  /// Builds the context buffer that gets signed alongside the inner payload.
  /// Format: `originPubkeyHash || destPubkeyHash || msgId`. All three are
  /// from the [TransportEnvelope] the body will ride in.
  static Uint8List contextBytes({
    required Uint8List originPubkeyHash,
    required Uint8List destPubkeyHash,
    required Uint8List msgId,
  }) {
    final out = Uint8List(
      originPubkeyHash.length + destPubkeyHash.length + msgId.length,
    );
    var c = 0;
    out.setRange(c, c += originPubkeyHash.length, originPubkeyHash);
    out.setRange(c, c += destPubkeyHash.length, destPubkeyHash);
    out.setRange(c, c + msgId.length, msgId);
    return out;
  }

  /// Sign [inner] under [signKeyPair] and return the wire bytes.
  /// [senderEdPub] must match the public key inside [signKeyPair] — passed
  /// separately to skip the async public-key extraction on the hot path.
  static Future<Uint8List> wrap({
    required Uint8List inner,
    required Uint8List context,
    required SimpleKeyPairData signKeyPair,
    required Uint8List senderEdPub,
  }) async {
    if (senderEdPub.length != pubLen) {
      throw ArgumentError('sender ed pub must be $pubLen B');
    }
    final material = Uint8List(context.length + pubLen + inner.length);
    var c = 0;
    material.setRange(c, c += context.length, context);
    material.setRange(c, c += pubLen, senderEdPub);
    material.setRange(c, c + inner.length, inner);

    final signature = await _ed25519.sign(material, keyPair: signKeyPair);
    if (signature.bytes.length != sigLen) {
      throw StateError('ed25519 produced ${signature.bytes.length}B, '
          'expected $sigLen — library mismatch?');
    }

    final out = Uint8List(headerLen + inner.length);
    out[0] = markerByte;
    out.setRange(1, 1 + pubLen, senderEdPub);
    out.setRange(1 + pubLen, headerLen, signature.bytes);
    out.setRange(headerLen, out.length, inner);
    return out;
  }

  /// Decode and verify [wire]. Throws [FormatException] when the marker
  /// byte or sizes are wrong, [SignatureVerificationException] when the
  /// signature doesn't validate under the embedded public key.
  ///
  /// Optional [expectedEdPub] enforces strict identity binding — if non-null
  /// and doesn't match the embedded ed pub, the call throws. Callers that
  /// already know the sender's verifying key (from a prior announcement)
  /// should pass it here.
  static Future<({Uint8List inner, Uint8List senderEdPub})> verify({
    required Uint8List wire,
    required Uint8List context,
    Uint8List? expectedEdPub,
  }) async {
    if (wire.length < headerLen) {
      throw const FormatException('signed payload shorter than header');
    }
    if (wire[0] != markerByte) {
      throw FormatException(
          'expected marker 0x${markerByte.toRadixString(16)}, '
          'got 0x${wire[0].toRadixString(16)}');
    }
    final senderEdPub = Uint8List.fromList(wire.sublist(1, 1 + pubLen));
    if (expectedEdPub != null && !_constTimeEq(senderEdPub, expectedEdPub)) {
      throw const SignatureVerificationException(
          'embedded ed pub does not match expected sender ed pub');
    }
    final sigBytes = wire.sublist(1 + pubLen, headerLen);
    final inner = Uint8List.fromList(wire.sublist(headerLen));

    final material = Uint8List(context.length + pubLen + inner.length);
    var c = 0;
    material.setRange(c, c += context.length, context);
    material.setRange(c, c += pubLen, senderEdPub);
    material.setRange(c, c + inner.length, inner);

    final ok = await _ed25519.verify(
      material,
      signature: Signature(
        sigBytes,
        publicKey: SimplePublicKey(senderEdPub, type: KeyPairType.ed25519),
      ),
    );
    if (!ok) {
      throw const SignatureVerificationException('Ed25519 signature invalid');
    }
    return (inner: inner, senderEdPub: senderEdPub);
  }

  static bool _constTimeEq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// Thrown by [SignedPayload.verify] when the signature doesn't validate or
/// the embedded pub doesn't match a required value.
class SignatureVerificationException implements Exception {
  const SignatureVerificationException(this.message);
  final String message;
  @override
  String toString() => 'SignatureVerificationException: $message';
}
