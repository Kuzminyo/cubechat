/// Spec-defined sizes for Noise_XX_25519_ChaChaPoly_BLAKE2s.
abstract final class NoiseConstants {
  /// Length of the BLAKE2s digest used as h / ck.
  static const int hashLen = 32;

  /// X25519 public/private key length.
  static const int dhLen = 32;

  /// AEAD tag (Poly1305) length.
  static const int macLen = 16;

  /// Maximum Noise plaintext per message (spec MAX_MESSAGE_LEN - tag).
  static const int maxMessageLen = 65535;

  /// Full protocol name string — used as the initial hash material.
  static const String protocolName = 'Noise_XX_25519_ChaChaPoly_BLAKE2s';
}
