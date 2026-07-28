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

  /// Protocol name for the IK pattern.
  ///
  /// Distinct from [protocolName] and that matters: the name is the first
  /// thing hashed into `h`, so the two patterns start from different chaining
  /// keys and a message from one can never be mistaken for a message of the
  /// other — it simply fails to decrypt.
  static const String protocolNameIk = 'Noise_IK_25519_ChaChaPoly_BLAKE2s';
}
