import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Self-authenticating wrapper for SealedBox plaintexts.
///
/// Wire layout (lives *inside* a SealedBox ciphertext):
///
/// ```
///   [marker        : 1 byte  = 0xA1]
///   [sender_ed_pub : 32 bytes — Ed25519 verifying key]
///   [signature     : 64 bytes — Ed25519 over context || ed_pub || ts || inner]
///   [timestampMs   : 8 bytes BE — sender wall-clock at send time]
///   [inner         : N bytes — the actual InnerPayload (type tag + body)]
/// ```
///
/// `context` is computed by [contextBytes] from the [TransportEnvelope]'s
/// origin/dest/msgId. It binds the signature to a specific route so the
/// frame can't be replayed under a different envelope.
///
/// The signed `timestampMs` lets the receiver enforce a freshness window:
/// a captured frame replayed after the dedup cache has expired (10 min)
/// still carries its original send time, so a stale-timestamp check drops
/// it. The timestamp is inside the signed material, so a relay can't
/// refresh it without the sender's Ed25519 key.
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

  /// Compact variant marker. Same guarantees as [markerByte] but the
  /// sender's Ed25519 pub is NOT embedded — the verifier supplies it from
  /// its KnownPeers cache. Saves 32 bytes, which matters for forward-secret
  /// frames that already carry a 76-byte X3DH header and must fit the
  /// 247-byte BLE MTU. Layout: `[0xA2][sig:64][ts:8][inner]`, signed over
  /// `context || ts || inner`.
  static const int markerCompactByte = 0xA2;

  static const int pubLen = 32;
  static const int sigLen = 64;
  static const int tsLen = 8;
  static const int headerLen = 1 + pubLen + sigLen + tsLen;
  static const int compactHeaderLen = 1 + sigLen + tsLen;

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
  /// [timestampMs] defaults to now; pass an explicit value only for tests.
  static Future<Uint8List> wrap({
    required Uint8List inner,
    required Uint8List context,
    required SimpleKeyPairData signKeyPair,
    required Uint8List senderEdPub,
    int? timestampMs,
  }) async {
    if (senderEdPub.length != pubLen) {
      throw ArgumentError('sender ed pub must be $pubLen B');
    }
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final tsBytes = _encodeTs(ts);

    final material =
        Uint8List(context.length + pubLen + tsLen + inner.length);
    var c = 0;
    material.setRange(c, c += context.length, context);
    material.setRange(c, c += pubLen, senderEdPub);
    material.setRange(c, c += tsLen, tsBytes);
    material.setRange(c, c + inner.length, inner);

    final signature = await _ed25519.sign(material, keyPair: signKeyPair);
    if (signature.bytes.length != sigLen) {
      throw StateError('ed25519 produced ${signature.bytes.length}B, '
          'expected $sigLen — library mismatch?');
    }

    final out = Uint8List(headerLen + inner.length);
    var o = 0;
    out[o++] = markerByte;
    out.setRange(o, o += pubLen, senderEdPub);
    out.setRange(o, o += sigLen, signature.bytes);
    out.setRange(o, o += tsLen, tsBytes);
    out.setRange(o, out.length, inner);
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
  static Future<({Uint8List inner, Uint8List senderEdPub, int timestampMs})>
      verify({
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
    var c = 1;
    final senderEdPub = Uint8List.fromList(wire.sublist(c, c += pubLen));
    if (expectedEdPub != null && !_constTimeEq(senderEdPub, expectedEdPub)) {
      throw const SignatureVerificationException(
          'embedded ed pub does not match expected sender ed pub');
    }
    final sigBytes = wire.sublist(c, c += sigLen);
    final tsBytes = wire.sublist(c, c += tsLen);
    final timestampMs = _decodeTs(tsBytes);
    final inner = Uint8List.fromList(wire.sublist(c));

    final material =
        Uint8List(context.length + pubLen + tsLen + inner.length);
    var m = 0;
    material.setRange(m, m += context.length, context);
    material.setRange(m, m += pubLen, senderEdPub);
    material.setRange(m, m += tsLen, tsBytes);
    material.setRange(m, m + inner.length, inner);

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
    return (inner: inner, senderEdPub: senderEdPub, timestampMs: timestampMs);
  }

  /// Compact wrap (no embedded ed pub). [senderEdPub] still goes into the
  /// signed material for domain separation but is not written to the wire;
  /// the verifier must already know it.
  static Future<Uint8List> wrapCompact({
    required Uint8List inner,
    required Uint8List context,
    required SimpleKeyPairData signKeyPair,
    required Uint8List senderEdPub,
    int? timestampMs,
  }) async {
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final tsBytes = _encodeTs(ts);
    final material =
        Uint8List(context.length + pubLen + tsLen + inner.length);
    var c = 0;
    material.setRange(c, c += context.length, context);
    material.setRange(c, c += pubLen, senderEdPub);
    material.setRange(c, c += tsLen, tsBytes);
    material.setRange(c, c + inner.length, inner);

    final signature = await _ed25519.sign(material, keyPair: signKeyPair);
    final out = Uint8List(compactHeaderLen + inner.length);
    var o = 0;
    out[o++] = markerCompactByte;
    out.setRange(o, o += sigLen, signature.bytes);
    out.setRange(o, o += tsLen, tsBytes);
    out.setRange(o, out.length, inner);
    return out;
  }

  /// Verify a compact wrap. [expectedEdPub] is REQUIRED — there's no embedded
  /// key to fall back on — and must be the sender's verifying key from a
  /// prior (signed) announcement.
  static Future<({Uint8List inner, int timestampMs})> verifyCompact({
    required Uint8List wire,
    required Uint8List context,
    required Uint8List expectedEdPub,
  }) async {
    if (wire.length < compactHeaderLen) {
      throw const FormatException('compact signed payload shorter than header');
    }
    if (wire[0] != markerCompactByte) {
      throw FormatException(
          'expected marker 0x${markerCompactByte.toRadixString(16)}, '
          'got 0x${wire[0].toRadixString(16)}');
    }
    var c = 1;
    final sigBytes = wire.sublist(c, c += sigLen);
    final tsBytes = wire.sublist(c, c += tsLen);
    final timestampMs = _decodeTs(tsBytes);
    final inner = Uint8List.fromList(wire.sublist(c));

    final material =
        Uint8List(context.length + pubLen + tsLen + inner.length);
    var m = 0;
    material.setRange(m, m += context.length, context);
    material.setRange(m, m += pubLen, expectedEdPub);
    material.setRange(m, m += tsLen, tsBytes);
    material.setRange(m, m + inner.length, inner);

    final ok = await _ed25519.verify(
      material,
      signature: Signature(
        sigBytes,
        publicKey: SimplePublicKey(expectedEdPub, type: KeyPairType.ed25519),
      ),
    );
    if (!ok) {
      throw const SignatureVerificationException(
          'Ed25519 signature invalid (compact)');
    }
    return (inner: inner, timestampMs: timestampMs);
  }

  static Uint8List _encodeTs(int ms) {
    final out = Uint8List(tsLen);
    var v = ms;
    for (var i = tsLen - 1; i >= 0; i--) {
      out[i] = v & 0xff;
      v >>= 8;
    }
    return out;
  }

  static int _decodeTs(List<int> bytes) {
    var v = 0;
    for (var i = 0; i < tsLen; i++) {
      v = (v << 8) | (bytes[i] & 0xff);
    }
    return v;
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
