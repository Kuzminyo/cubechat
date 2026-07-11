import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/stream/chacha7539.dart';

import 'secp256k1.dart';

/// NIP-44 v2 payload encryption — the conversation-encryption primitive Nostr
/// DMs (NIP-17) are built on.
///
/// Construction (nip-44 §2):
///   conversation_key = HKDF-extract(salt="nip44-v2", IKM=ecdh_x)
///   message_keys     = HKDF-expand(conversation_key, info=nonce, L=76)
///                      → chacha_key[32] ‖ chacha_nonce[12] ‖ hmac_key[32]
///   ciphertext       = ChaCha20(chacha_key, chacha_nonce, pad(plaintext))
///   mac              = HMAC-SHA256(hmac_key, nonce ‖ ciphertext)
///   payload          = base64( 0x02 ‖ nonce[32] ‖ ciphertext ‖ mac[32] )
///
/// SHA-256/HMAC come from `package:crypto`, ChaCha20 (RFC 8439, 32-bit counter
/// from 0) from pointycastle, and the ECDH x-coordinate from [Secp256k1]. The
/// whole thing is pinned to the official NIP-44 test vectors.
class Nip44 {
  Nip44._();

  static const int _version = 2;
  static const int _minPlaintext = 1;
  static const int _maxPlaintext = 65535;

  static final _rng = Random.secure();

  /// Symmetric conversation key from our [privHex] and their x-only [pubHex].
  /// Commutative: `conversationKey(a, pubB) == conversationKey(b, pubA)`.
  static Uint8List conversationKey(String privHex, String pubHex) {
    final sharedX = Secp256k1.ecdhSharedX(privHex, pubHex);
    // HKDF-extract(salt, IKM) == HMAC(salt, IKM).
    return Uint8List.fromList(
      Hmac(sha256, utf8.encode('nip44-v2')).convert(sharedX).bytes,
    );
  }

  /// Encrypt with a fresh random nonce.
  static String encrypt(String plaintext, Uint8List conversationKey) =>
      encryptWithNonce(plaintext, conversationKey, _randomNonce());

  /// Encrypt under an explicit 32-byte [nonce]. Exposed for test vectors;
  /// production callers use [encrypt].
  static String encryptWithNonce(
    String plaintext,
    Uint8List conversationKey,
    Uint8List nonce,
  ) {
    if (nonce.length != 32) throw ArgumentError('nonce must be 32 bytes');
    final padded = _pad(Uint8List.fromList(utf8.encode(plaintext)));
    final (chachaKey, chachaNonce, hmacKey) = _messageKeys(conversationKey, nonce);
    final ciphertext = _chacha20(chachaKey, chachaNonce, padded);
    final mac = _hmacWithAad(hmacKey, ciphertext, nonce);

    final out = Uint8List(1 + 32 + ciphertext.length + 32);
    var o = 0;
    out[o++] = _version;
    out.setRange(o, o += 32, nonce);
    out.setRange(o, o += ciphertext.length, ciphertext);
    out.setRange(o, o += 32, mac);
    return base64.encode(out);
  }

  /// Decrypt a base64 payload. Throws [FormatException] on a bad version,
  /// truncation, or a MAC that doesn't verify.
  static String decrypt(String payload, Uint8List conversationKey) {
    if (payload.isEmpty || payload.startsWith('#')) {
      throw const FormatException('unsupported NIP-44 version');
    }
    final data = base64.decode(base64.normalize(payload));
    if (data.length < 1 + 32 + 1 + 32) {
      throw const FormatException('payload too short');
    }
    if (data[0] != _version) {
      throw FormatException('unsupported NIP-44 version ${data[0]}');
    }
    final nonce = Uint8List.sublistView(data, 1, 33);
    final ciphertext = Uint8List.sublistView(data, 33, data.length - 32);
    final mac = Uint8List.sublistView(data, data.length - 32);

    final (chachaKey, chachaNonce, hmacKey) = _messageKeys(conversationKey, nonce);
    final expected = _hmacWithAad(hmacKey, ciphertext, nonce);
    if (!_constTimeEq(expected, mac)) {
      throw const FormatException('invalid MAC');
    }
    return _unpad(_chacha20(chachaKey, chachaNonce, ciphertext));
  }

  // ---- key schedule ----

  /// HKDF-expand(PRK=conversationKey, info=nonce, L=76) split into the three
  /// sub-keys.
  static (Uint8List, Uint8List, Uint8List) _messageKeys(
    Uint8List prk,
    Uint8List nonce,
  ) {
    final okm = <int>[];
    var t = const <int>[];
    var counter = 1;
    while (okm.length < 76) {
      t = Hmac(sha256, prk).convert([...t, ...nonce, counter]).bytes;
      okm.addAll(t);
      counter++;
    }
    return (
      Uint8List.fromList(okm.sublist(0, 32)),
      Uint8List.fromList(okm.sublist(32, 44)),
      Uint8List.fromList(okm.sublist(44, 76)),
    );
  }

  static Uint8List _hmacWithAad(Uint8List key, Uint8List message, Uint8List aad) {
    return Uint8List.fromList(
      Hmac(sha256, key).convert([...aad, ...message]).bytes,
    );
  }

  static Uint8List _chacha20(Uint8List key, Uint8List nonce, Uint8List data) {
    final engine = ChaCha7539Engine()
      ..init(true, ParametersWithIV<KeyParameter>(KeyParameter(key), nonce));
    final out = Uint8List(data.length);
    engine.processBytes(data, 0, data.length, out, 0);
    return out;
  }

  // ---- padding (nip-44 §2) ----

  /// Content is prefixed with its length (u16 BE), then zero-padded up to the
  /// next [calcPaddedLen] bucket — so ciphertext length reveals only a coarse
  /// bucket, not the exact message length.
  static Uint8List _pad(Uint8List plaintext) {
    final len = plaintext.length;
    if (len < _minPlaintext || len > _maxPlaintext) {
      throw ArgumentError('plaintext length $len out of range');
    }
    final paddedLen = calcPaddedLen(len);
    final out = Uint8List(2 + paddedLen);
    out[0] = (len >> 8) & 0xff;
    out[1] = len & 0xff;
    out.setRange(2, 2 + len, plaintext);
    return out;
  }

  static String _unpad(Uint8List padded) {
    if (padded.length < 2) throw const FormatException('padding truncated');
    final len = (padded[0] << 8) | padded[1];
    if (len < _minPlaintext || 2 + len > padded.length) {
      throw const FormatException('invalid declared length');
    }
    // The bucket must be exactly what pad() would have produced — otherwise the
    // padding was tampered with.
    if (padded.length != 2 + calcPaddedLen(len)) {
      throw const FormatException('padding length mismatch');
    }
    return utf8.decode(padded.sublist(2, 2 + len));
  }

  /// Padded content length for an [unpaddedLen]-byte message (nip-44 §2).
  /// Messages ≤32B share a 32B bucket; larger ones round up to power-of-two
  /// chunks. Public for the vector tests.
  static int calcPaddedLen(int unpaddedLen) {
    if (unpaddedLen <= 0) throw ArgumentError('length must be positive');
    if (unpaddedLen <= 32) return 32;
    final nextPower = 1 << (unpaddedLen - 1).bitLength;
    final chunk = nextPower <= 256 ? 32 : nextPower ~/ 8;
    return chunk * (((unpaddedLen - 1) ~/ chunk) + 1);
  }

  static Uint8List _randomNonce() {
    final n = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      n[i] = _rng.nextInt(256);
    }
    return n;
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
