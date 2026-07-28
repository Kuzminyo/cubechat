import 'dart:typed_data';

import 'noise_cipher_state.dart';

/// What [NoiseSession] needs from a handshake, whichever pattern is running.
///
/// Two patterns are in use and they are not interchangeable at the call site:
/// XX can start a conversation with a stranger but hands the responder's
/// long-term key to whoever dials it, while IK never transmits that key but
/// requires the initiator to hold it already. Everything above this interface
/// drives them identically — the difference is only in who is allowed to
/// start, which is a policy decision, not a protocol one.
///
/// Both implementations already had these exact signatures; this only names
/// them so the session layer stops caring which one it holds.
abstract interface class NoiseHandshake {
  /// True once both sides have derived transport keys.
  bool get handshakeFinished;

  /// Available after [handshakeFinished]. First is send for the initiator.
  NoiseCipherState? get sendCipherState;
  NoiseCipherState? get receiveCipherState;

  /// The peer's authenticated static key, once the pattern has revealed it.
  Uint8List? get remoteStaticPublicKey;

  /// Write the next outbound handshake message, optionally carrying a payload.
  Future<Uint8List> writeMessage([Uint8List? payload]);

  /// Read an inbound handshake message, returning its decrypted payload.
  Future<Uint8List> readMessage(Uint8List message);
}
