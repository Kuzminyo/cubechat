import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'noise_cipher_state.dart';
import 'noise_constants.dart';

/// SymmetricState from §5.2 of the Noise spec.
///
/// Maintains:
///   - `h` — running hash chained through every payload and DH output
///   - `ck` — chaining key, fed into HKDF on every MixKey
///   - `cipherState` — the CipherState used by EncryptAndHash / DecryptAndHash
class NoiseSymmetricState {
  NoiseSymmetricState._(this._h, this._ck, this._cipher);

  Uint8List _h;
  Uint8List _ck;
  final NoiseCipherState _cipher;

  static final _blake2s = Blake2s();

  /// Initializes a SymmetricState with the protocol name.
  ///
  /// If `len(protocol_name) <= HASHLEN` we right-pad with zeros, otherwise
  /// `h = HASH(protocol_name)`. We always go through the hash branch — our
  /// protocol name is 33 bytes (>32) so we'd hit it anyway, and hashing
  /// always-shorter strings is harmless.
  static Future<NoiseSymmetricState> initialize(String protocolName) async {
    final nameBytes = Uint8List.fromList(utf8.encode(protocolName));
    final h = await _hash(nameBytes);
    final ck = Uint8List.fromList(h);
    return NoiseSymmetricState._(h, ck, NoiseCipherState());
  }

  Uint8List get handshakeHash => Uint8List.fromList(_h);

  bool get hasKey => _cipher.hasKey;

  Future<void> mixHash(Uint8List data) async {
    final combined = Uint8List(_h.length + data.length)
      ..setRange(0, _h.length, _h)
      ..setRange(_h.length, _h.length + data.length, data);
    _h = await _hash(combined);
  }

  /// HKDF as defined by Noise spec §4.3 — emits two 32-byte outputs.
  Future<List<Uint8List>> _hkdf(Uint8List ikm, int numOutputs) async {
    assert(numOutputs == 2 || numOutputs == 3);
    final tempKey = await _hmac(_ck, ikm);
    final output1 = await _hmac(tempKey, Uint8List.fromList(const [0x01]));
    final output2Input = Uint8List(output1.length + 1)
      ..setRange(0, output1.length, output1)
      ..[output1.length] = 0x02;
    final output2 = await _hmac(tempKey, output2Input);
    if (numOutputs == 2) return [output1, output2];
    final output3Input = Uint8List(output2.length + 1)
      ..setRange(0, output2.length, output2)
      ..[output2.length] = 0x03;
    final output3 = await _hmac(tempKey, output3Input);
    return [output1, output2, output3];
  }

  Future<void> mixKey(Uint8List inputKeyMaterial) async {
    final outputs = await _hkdf(inputKeyMaterial, 2);
    _ck = outputs[0];
    _cipher.initializeKey(outputs[1]);
  }

  Future<Uint8List> encryptAndHash(Uint8List plaintext) async {
    final ciphertext = await _cipher.encryptWithAd(_h, plaintext);
    await mixHash(ciphertext);
    return ciphertext;
  }

  Future<Uint8List> decryptAndHash(Uint8List ciphertext) async {
    final plaintext = await _cipher.decryptWithAd(_h, ciphertext);
    await mixHash(ciphertext);
    return plaintext;
  }

  /// Split() — finalizes the handshake and returns two CipherStates.
  /// The first is the initiator's send / responder's receive; the second is
  /// the reverse.
  Future<(NoiseCipherState, NoiseCipherState)> split() async {
    final outputs = await _hkdf(Uint8List(0), 2);
    final c1 = NoiseCipherState()..initializeKey(outputs[0]);
    final c2 = NoiseCipherState()..initializeKey(outputs[1]);
    return (c1, c2);
  }

  // ----- low-level primitives -----

  static Future<Uint8List> _hash(Uint8List data) async {
    final d = await _blake2s.hash(data);
    return Uint8List.fromList(d.bytes);
  }

  /// HMAC-BLAKE2s (HASHLEN = 32, BLOCKLEN = 64) — per Noise spec §4.3.
  static Future<Uint8List> _hmac(Uint8List key, Uint8List data) async {
    const blockLen = 64;
    Uint8List keyBlock;
    if (key.length > blockLen) {
      keyBlock = await _hash(key);
    } else {
      keyBlock = Uint8List(blockLen)..setRange(0, key.length, key);
    }
    final inner = Uint8List(blockLen);
    final outer = Uint8List(blockLen);
    for (var i = 0; i < blockLen; i++) {
      inner[i] = keyBlock[i] ^ 0x36;
      outer[i] = keyBlock[i] ^ 0x5C;
    }
    final innerInput = Uint8List(blockLen + data.length)
      ..setRange(0, blockLen, inner)
      ..setRange(blockLen, blockLen + data.length, data);
    final innerHash = await _hash(innerInput);
    final outerInput = Uint8List(blockLen + innerHash.length)
      ..setRange(0, blockLen, outer)
      ..setRange(blockLen, blockLen + innerHash.length, innerHash);
    return _hash(outerInput);
  }
}
