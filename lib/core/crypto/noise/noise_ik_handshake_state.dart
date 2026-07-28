import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'noise_cipher_state.dart';
import 'noise_handshake.dart';
import 'noise_constants.dart';
import 'noise_symmetric_state.dart';

/// Noise_IK_25519_ChaChaPoly_BLAKE2s HandshakeState.
///
/// ```
///   <- s                     (pre-message: the initiator already has it)
///   ...
///   -> e, es, s, ss
///   <- e, ee, se
/// ```
///
/// ## Why this exists next to XX
///
/// XX transmits the responder's static key in its second message. It is
/// encrypted, so a passive listener cannot read it — but the *initiator* can,
/// and the initiator at that point is anyone who opened a connection. So a
/// stranger who simply dials us walks away with the long-term public key that
/// identifies this device forever, and from which every rotating routing id is
/// derived. Rotation and sealed announcements are undone by one deliberate
/// connection.
///
/// IK closes that: the responder never sends its static key at all. The
/// initiator has to hold it already, and proves so in the very first message
/// by encrypting under `es` — a DH against that key. Someone without it cannot
/// produce a message we can open, so they learn nothing and get no session.
///
/// The cost is the reason XX is still here: IK cannot start a conversation with
/// a stranger, because by construction you must know them first. That is
/// exactly the trade the "Discoverable nearby" setting decides.
///
/// ## Identity hiding
///
/// The initiator's own static travels in message 1 encrypted under `es`, so it
/// is hidden from observers but readable by the responder — mutual
/// authentication, which is what we want. Note the standard IK caveat: an
/// attacker who later compromises the responder's static key can decrypt a
/// recorded message 1 and learn who was talking to them. Message contents stay
/// safe (transport keys come from the ephemerals), and cubechat's application
/// layer adds its own forward secrecy on top.
class NoiseIkHandshakeState implements NoiseHandshake {
  NoiseIkHandshakeState._({
    required this.isInitiator,
    required this.localStatic,
    required this.symmetric,
    required SimplePublicKey? remoteStatic,
  }) : _remoteStatic = remoteStatic;

  final bool isInitiator;
  final SimpleKeyPair localStatic;
  final NoiseSymmetricState symmetric;

  SimpleKeyPair? _localEphemeral;
  SimplePublicKey? _remoteStatic;
  SimplePublicKey? _remoteEphemeral;

  int _messageIndex = 0;
  bool _done = false;

  NoiseCipherState? _sendCs;
  NoiseCipherState? _recvCs;

  static final _x25519 = X25519();

  /// IK is two messages.
  static const int messageCount = 2;

  bool get handshakeFinished => _done;
  NoiseCipherState? get sendCipherState => _sendCs;
  NoiseCipherState? get receiveCipherState => _recvCs;
  Uint8List? get remoteStaticPublicKey =>
      _remoteStatic == null ? null : Uint8List.fromList(_remoteStatic!.bytes);

  /// [remoteStatic] is required for the initiator (it is the whole premise of
  /// the pattern) and must be null for the responder, which learns the peer's
  /// key from message 1.
  ///
  /// Both sides hash the *responder's* static key into `h` before anything is
  /// sent — that is the `<- s` pre-message. For the initiator that is the key
  /// it was given; for the responder it is its own. Get this wrong on either
  /// side and every subsequent decryption fails, which is the failure mode this
  /// pattern is supposed to produce for a stranger.
  static Future<NoiseIkHandshakeState> initialize({
    required bool isInitiator,
    required SimpleKeyPair localStatic,
    Uint8List? remoteStatic,
  }) async {
    if (isInitiator && (remoteStatic == null || remoteStatic.length != NoiseConstants.dhLen)) {
      throw const NoiseException(
        'IK initiator needs the responder\'s static public key',
      );
    }
    final sym =
        await NoiseSymmetricState.initialize(NoiseConstants.protocolNameIk);
    // No prologue.
    await sym.mixHash(Uint8List(0));

    final Uint8List responderStatic;
    if (isInitiator) {
      responderStatic = remoteStatic!;
    } else {
      final pub = await localStatic.extractPublicKey();
      responderStatic = Uint8List.fromList(pub.bytes);
    }
    // The `<- s` pre-message.
    await sym.mixHash(responderStatic);

    return NoiseIkHandshakeState._(
      isInitiator: isInitiator,
      localStatic: localStatic,
      symmetric: sym,
      remoteStatic: isInitiator
          ? SimplePublicKey(remoteStatic!, type: KeyPairType.x25519)
          : null,
    );
  }

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
      case 0: // initiator: e, es, s, ss
        _localEphemeral = await _x25519.newKeyPair();
        final epub = await _publicBytes(_localEphemeral!);
        out.add(epub);
        await symmetric.mixHash(epub);

        // es — initiator side: our ephemeral against their static.
        await symmetric.mixKey(await _dh(_localEphemeral!, _remoteStatic!));

        final spub = await _publicBytes(localStatic);
        out.add(await symmetric.encryptAndHash(spub));

        // ss — both statics.
        await symmetric.mixKey(await _dh(localStatic, _remoteStatic!));

      case 1: // responder: e, ee, se
        _localEphemeral = await _x25519.newKeyPair();
        final epub = await _publicBytes(_localEphemeral!);
        out.add(epub);
        await symmetric.mixHash(epub);

        await symmetric.mixKey(await _dh(_localEphemeral!, _remoteEphemeral!));
        // se — responder side: our ephemeral against their static.
        await symmetric.mixKey(await _dh(_localEphemeral!, _remoteStatic!));

      default:
        throw const NoiseException('IK pattern is only 2 messages');
    }

    out.add(await symmetric.encryptAndHash(payload));

    _messageIndex++;
    if (_messageIndex == messageCount) await _split();

    return out.toBytes();
  }

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
      case 0: // responder reads: e, es, s, ss
        final epub = slice(NoiseConstants.dhLen);
        _remoteEphemeral = SimplePublicKey(epub, type: KeyPairType.x25519);
        await symmetric.mixHash(epub);

        // es — responder side: our static against their ephemeral. This is the
        // step a stranger cannot match: without our public key they encrypted
        // under a different chaining key, and the decrypt below fails.
        await symmetric.mixKey(await _dh(localStatic, _remoteEphemeral!));

        final encryptedS = slice(NoiseConstants.dhLen + NoiseConstants.macLen);
        final rs = await symmetric.decryptAndHash(encryptedS);
        _remoteStatic = SimplePublicKey(rs, type: KeyPairType.x25519);

        await symmetric.mixKey(await _dh(localStatic, _remoteStatic!));

      case 1: // initiator reads: e, ee, se
        final epub = slice(NoiseConstants.dhLen);
        _remoteEphemeral = SimplePublicKey(epub, type: KeyPairType.x25519);
        await symmetric.mixHash(epub);

        await symmetric.mixKey(await _dh(_localEphemeral!, _remoteEphemeral!));
        // se — initiator side: our static against their ephemeral.
        await symmetric.mixKey(await _dh(localStatic, _remoteEphemeral!));

      default:
        throw const NoiseException('IK pattern is only 2 messages');
    }

    final payload = await symmetric.decryptAndHash(message.sublist(cursor));

    _messageIndex++;
    if (_messageIndex == messageCount) await _split();

    return payload;
  }

  Future<void> _split() async {
    final (c1, c2) = await symmetric.split();
    if (isInitiator) {
      _sendCs = c1;
      _recvCs = c2;
    } else {
      _sendCs = c2;
      _recvCs = c1;
    }
    _done = true;
  }

  Future<Uint8List> _dh(
    SimpleKeyPair localPair,
    SimplePublicKey remotePub,
  ) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: localPair,
      remotePublicKey: remotePub,
    );
    return Uint8List.fromList(await shared.extractBytes());
  }

  Future<Uint8List> _publicBytes(SimpleKeyPair pair) async {
    final pub = await pair.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }
}
