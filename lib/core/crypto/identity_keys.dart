import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// Long-term Curve25519 identity for a cubechat node.
///
/// The static key pair is the cryptographic identity the Noise XX handshake
/// authenticates. The fingerprint is what the user compares with another peer
/// to verify the connection wasn't tampered with.
@immutable
class IdentityKeys {
  IdentityKeys({
    required this.publicKey,
    required this.privateKey,
    required this.signPublicKey,
    required this.signPrivateKey,
  })  : assert(publicKey.length == 32, 'X25519 public key must be 32 bytes'),
        assert(privateKey.length == 32, 'X25519 private key must be 32 bytes'),
        assert(signPublicKey.length == 32, 'Ed25519 public must be 32 bytes'),
        assert(signPrivateKey.length == 32, 'Ed25519 seed must be 32 bytes');

  /// X25519 public key — used for ECDH inside SealedBox and as the routing
  /// identity hashed into the envelope's originPubkeyHash.
  final Uint8List publicKey;
  final Uint8List privateKey;

  /// Ed25519 public key — used to verify Signature on every received
  /// message body. Separate from the X25519 key because Curve25519 doesn't
  /// natively sign.
  final Uint8List signPublicKey;

  /// Ed25519 seed (32 bytes). The `cryptography` package re-derives the
  /// 64-byte expanded private key from this on every sign.
  final Uint8List signPrivateKey;

  /// Returns the `cryptography` SimpleKeyPair for use with `X25519` operations.
  SimpleKeyPairData asKeyPair() {
    return SimpleKeyPairData(
      privateKey,
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
  }

  /// Returns the `cryptography` SimpleKeyPair for use with `Ed25519`
  /// signing.
  SimpleKeyPairData asSignKeyPair() {
    return SimpleKeyPairData(
      signPrivateKey,
      publicKey: SimplePublicKey(signPublicKey, type: KeyPairType.ed25519),
      type: KeyPairType.ed25519,
    );
  }

  /// 32-byte BLAKE2s digest of the public key, presented as 16 groups of 4
  /// lowercase hex chars: `8a3f 19c2 7e5b 4d09 a1f4 2c88 6b3d 0e57 …`.
  ///
  /// Two users compare the first ~8 groups verbally to verify identity.
  Future<String> fingerprint() async {
    final digest = await Blake2s().hash(publicKey);
    return formatFingerprint(Uint8List.fromList(digest.bytes));
  }

  /// Compact 8-group fingerprint (first 16 bytes / 32 hex chars), suitable for
  /// display in chat headers.
  Future<String> shortFingerprint() async {
    final digest = await Blake2s().hash(publicKey);
    final bytes = Uint8List.fromList(digest.bytes).sublist(0, 16);
    return formatFingerprint(bytes);
  }

  static String formatFingerprint(Uint8List bytes) {
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final groups = <String>[];
    for (var i = 0; i < hex.length; i += 4) {
      groups.add(hex.substring(i, (i + 4).clamp(0, hex.length)));
    }
    return groups.join(' ');
  }
}
