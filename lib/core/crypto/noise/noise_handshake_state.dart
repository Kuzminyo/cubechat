import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'noise_cipher_state.dart';
import 'noise_constants.dart';
import 'noise_symmetric_state.dart';

/// Noise_XX_25519_ChaChaPoly_BLAKE2s HandshakeState.
///
/// XX is a mutual-auth pattern with three messages:
///
/// ```
///   -> e
///   <- e, ee, s, es
///   -> s, se
/// ```
///
/// After the third message both sides Split() the SymmetricState into two
/// CipherStates used for transport (one per direction).
class NoiseHandshakeState {
  NoiseHandshakeState._({
    required this.isInitiator,
    required this.localStatic,
    required this.symmetric,
  });

  final bool isInitiator;
  final SimpleKeyPair localStatic;
  final NoiseSymmetricState symmetric;

  SimpleKeyPair? _localEphemeral;
  SimplePublicKey? _remoteStatic;
  SimplePublicKey? _remoteEphemeral;

  int _messageIndex = 0;
  bool _done = false;

  /// Set once Split() has been called. The first CipherState is "send" for
  /// the initiator / "receive" for the responder; the second is the reverse.
  NoiseCipherState? _sendCs;
  NoiseCipherState? _recvCs;

  static final _x25519 = X25519();

  /// Spec-defined "pattern length" for XX (3 messages total).
  static const int messageCount = 3;

  bool get handshakeFinished => _done;
  NoiseCipherState? get sendCipherState => _sendCs;
  NoiseCipherState? get receiveCipherState => _recvCs;
  Uint8List? get remoteStaticPublicKey =>
      _remoteStatic == null ? null : Uint8List.fromList(_remoteStatic!.bytes);

  static Future<NoiseHandshakeState> initialize({
    required bool isInitiator,
    required SimpleKeyPair localStatic,
  }) async {
    final sym = await NoiseSymmetricState.initialize(NoiseConstants.protocolName);
    // XX pattern has no pre-message public keys, so the prologue MixHash
    // just absorbs an empty byte string per the spec.
    await sym.mixHash(Uint8List(0));
    return NoiseHandshakeState._(
      isInitiator: isInitiator,
      localStatic: localStatic,
      symmetric: sym,
    );
  }

  /// Writes the next outbound handshake message, optionally attaching an
  /// application payload (encrypted with whatever key state is current).
  Future<Uint8List> writeMessage([Uint8List? payload]) async {
    payload ??= Uint8List(0);
    if (_done) {
      throw const NoiseException('handshake already finished');
    }
    final isInitiatorTurn = (_messageIndex % 2 == 0) == isInitiator;
    if (!isInitiatorTurn) {
      throw const NoiseException('not this side\'s turn to write');
    }

    final out = BytesBuilder(copy: false);

    switch (_messageIndex) {
      case 0: // initiator: e
        _localEphemeral = await _x25519.newKeyPair();
        final epub = await _publicBytes(_localEphemeral!);
        out.add(epub);
        await symmetric.mixHash(epub);
        break;

      case 1: // responder: e, ee, s, es
        _localEphemeral = await _x25519.newKeyPair();
        final epub = await _publicBytes(_localEphemeral!);
        out.add(epub);
        await symmetric.mixHash(epub);
        await symmetric.mixKey(await _dh(_localEphemeral!, _remoteEphemeral!));

        final spub = await _publicBytes(localStatic);
        final encryptedS = await symmetric.encryptAndHash(spub);
        out.add(encryptedS);

        await symmetric.mixKey(await _dh(localStatic, _remoteEphemeral!));
        break;

      case 2: // initiator: s, se
        final spub = await _publicBytes(localStatic);
        final encryptedS = await symmetric.encryptAndHash(spub);
        out.add(encryptedS);
        await symmetric.mixKey(await _dh(localStatic, _remoteEphemeral!));
        break;

      default:
        throw const NoiseException('XX pattern is only 3 messages');
    }

    final encryptedPayload = await symmetric.encryptAndHash(payload);
    out.add(encryptedPayload);

    _messageIndex++;
    if (_messageIndex == messageCount) await _split();

    return out.toBytes();
  }

  /// Reads an inbound handshake message and returns the decrypted application
  /// payload (zero-length if the sender didn't attach one).
  Future<Uint8List> readMessage(Uint8List message) async {
    if (_done) {
      throw const NoiseException('handshake already finished');
    }
    final isInitiatorTurn = (_messageIndex % 2 == 0) == isInitiator;
    if (isInitiatorTurn) {
      throw const NoiseException('not this side\'s turn to read');
    }

    var cursor = 0;
    Uint8List slice(int n) {
      if (cursor + n > message.length) {
        throw const NoiseException('handshake message truncated');
      }
      final s = message.sublist(cursor, cursor + n);
      cursor += n;
      return s;
    }

    switch (_messageIndex) {
      case 0: // responder reads: e
        final epub = slice(NoiseConstants.dhLen);
        _remoteEphemeral = SimplePublicKey(epub, type: KeyPairType.x25519);
        await symmetric.mixHash(epub);
        break;

      case 1: // initiator reads: e, ee, s, es
        final epub = slice(NoiseConstants.dhLen);
        _remoteEphemeral = SimplePublicKey(epub, type: KeyPairType.x25519);
        await symmetric.mixHash(epub);
        await symmetric.mixKey(await _dh(_localEphemeral!, _remoteEphemeral!));

        final encryptedS = slice(NoiseConstants.dhLen + NoiseConstants.macLen);
        final rs = await symmetric.decryptAndHash(encryptedS);
        _remoteStatic = SimplePublicKey(rs, type: KeyPairType.x25519);

        await symmetric.mixKey(await _dh(_localEphemeral!, _remoteStatic!));
        break;

      case 2: // responder reads: s, se
        final encryptedS = slice(NoiseConstants.dhLen + NoiseConstants.macLen);
        final rs = await symmetric.decryptAndHash(encryptedS);
        _remoteStatic = SimplePublicKey(rs, type: KeyPairType.x25519);

        await symmetric.mixKey(await _dh(_localEphemeral!, _remoteStatic!));
        break;

      default:
        throw const NoiseException('XX pattern is only 3 messages');
    }

    final encryptedPayload = message.sublist(cursor);
    final payload = await symmetric.decryptAndHash(encryptedPayload);

    _messageIndex++;
    if (_messageIndex == messageCount) await _split();

    return payload;
  }

  Future<void> _split() async {
    final (c1, c2) = await symmetric.split();
    // Per Noise spec: the initiator's first CipherState becomes its send
    // direction, second is its receive.
    if (isInitiator) {
      _sendCs = c1;
      _recvCs = c2;
    } else {
      _sendCs = c2;
      _recvCs = c1;
    }
    _done = true;
  }

  // ----- DH helper -----

  Future<Uint8List> _dh(SimpleKeyPair localPair, SimplePublicKey remotePub) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: localPair,
      remotePublicKey: remotePub,
    );
    final bytes = await shared.extractBytes();
    return Uint8List.fromList(bytes);
  }

  Future<Uint8List> _publicBytes(SimpleKeyPair pair) async {
    final pub = await pair.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }
}
