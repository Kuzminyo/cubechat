import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'noise_constants.dart';

/// CipherState from §5.1 of the Noise spec.
///
/// Wraps a 256-bit symmetric key plus a 64-bit message counter (nonce). On
/// every encrypt/decrypt the counter is incremented; reuse is a security
/// disaster, so we hard-fail if the counter wraps.
///
/// All operations are async because `cryptography`'s ChaCha20-Poly1305 is
/// async (it dispatches to platform-accelerated implementations).
class NoiseCipherState {
  NoiseCipherState();

  Uint8List? _key;
  int _nonce = 0;

  static final _aead = Chacha20.poly1305Aead();

  bool get hasKey => _key != null;

  void initializeKey(Uint8List key) {
    if (key.length != 32) {
      throw ArgumentError('CipherState key must be 32 bytes');
    }
    _key = Uint8List.fromList(key);
    _nonce = 0;
  }

  Future<Uint8List> encryptWithAd(Uint8List ad, Uint8List plaintext) async {
    if (_key == null) return Uint8List.fromList(plaintext);
    final n = _consumeNonce();
    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(_key!),
      nonce: _nonceBytes(n),
      aad: ad,
    );
    final out = Uint8List(box.cipherText.length + box.mac.bytes.length);
    out.setRange(0, box.cipherText.length, box.cipherText);
    out.setRange(box.cipherText.length, out.length, box.mac.bytes);
    return out;
  }

  Future<Uint8List> decryptWithAd(Uint8List ad, Uint8List ciphertext) async {
    if (_key == null) return Uint8List.fromList(ciphertext);
    if (ciphertext.length < NoiseConstants.macLen) {
      throw const NoiseException('ciphertext shorter than MAC');
    }
    final n = _consumeNonce();
    final cipher = ciphertext.sublist(0, ciphertext.length - NoiseConstants.macLen);
    final mac = ciphertext.sublist(ciphertext.length - NoiseConstants.macLen);
    final box = SecretBox(cipher, nonce: _nonceBytes(n), mac: Mac(mac));
    try {
      final plain = await _aead.decrypt(box, secretKey: SecretKey(_key!), aad: ad);
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw const NoiseException('AEAD authentication failed');
    }
  }

  /// Resets the key and counter — used during emergency wipe.
  void clear() {
    if (_key != null) {
      _key!.fillRange(0, _key!.length, 0);
      _key = null;
    }
    _nonce = 0;
  }

  int _consumeNonce() {
    // 2^64 - 1 is reserved as "nonce exhausted" sentinel per spec.
    if (_nonce >= 0xFFFFFFFFFFFFFFFF) {
      throw const NoiseException('Noise CipherState nonce exhausted');
    }
    return _nonce++;
  }

  /// Noise nonce format: 4 zero bytes || 8-byte little-endian counter.
  Uint8List _nonceBytes(int n) {
    final out = Uint8List(12);
    final bd = ByteData.view(out.buffer);
    bd.setUint64(4, n, Endian.little);
    return out;
  }
}

class NoiseException implements Exception {
  const NoiseException(this.message);
  final String message;
  @override
  String toString() => 'NoiseException: $message';
}
