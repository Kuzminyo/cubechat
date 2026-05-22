import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Self-authenticating "I am here" payload broadcast over the mesh.
///
/// Wire layout (lives inside a [TransportEnvelope] with `dest = broadcast`,
/// wrapped in a [FrameType.peerAnnouncement] frame):
///
/// ```
///   [version  :  1 byte = 0x03]
///   [x25519   : 32 bytes — Curve25519 static (encryption + routing identity)]
///   [ed25519  : 32 bytes — Ed25519 verifying key (message signatures)]
///   [spk      : 32 bytes — X25519 signed prekey (forward-secret messaging)]
///   [nameLen  :  1 byte]
///   [name     : nameLen bytes UTF-8]
///   [sig      : 64 bytes — Ed25519 over (version || x25519 || ed25519 || spk || name)]
/// ```
///
/// The signature locks the (x25519_pub ↔ ed25519_pub ↔ spk ↔ nickname)
/// binding so Mallory can't announce "I am Alice's X25519 hash" with their
/// own keys — any forgery attempt would need Alice's Ed25519 private key.
/// Receivers verify the sig, then cache the bundle (incl. the signed prekey)
/// in KnownPeers; senders use the cached SPK to open a forward-secret X3DH
/// session.
class PeerAnnouncement {
  PeerAnnouncement({
    required this.pubkey,
    required this.signPubkey,
    required this.signedPrekeyPub,
    required this.nickname,
  })  : assert(pubkey.length == pubkeyLen, 'pubkey must be $pubkeyLen B'),
        assert(signPubkey.length == pubkeyLen,
            'signPubkey must be $pubkeyLen B'),
        assert(signedPrekeyPub.length == pubkeyLen,
            'signedPrekeyPub must be $pubkeyLen B');

  /// X25519 long-term encryption key.
  final Uint8List pubkey;

  /// Ed25519 long-term verifying key.
  final Uint8List signPubkey;

  /// X25519 signed prekey — the recipient-side half of forward-secret X3DH.
  final Uint8List signedPrekeyPub;

  final String nickname;

  static const int version = 0x03;
  static const int pubkeyLen = 32;
  static const int sigLen = 64;

  static final _ed25519 = Ed25519();

  /// Build, sign, and return the wire bytes. [signKeyPair] is the holder's
  /// Ed25519 key pair (matching [signPubkey]).
  Future<Uint8List> sign(SimpleKeyPairData signKeyPair) async {
    final body = _encodeBody();
    final signature = await _ed25519.sign(body, keyPair: signKeyPair);
    final out = Uint8List(body.length + sigLen);
    out.setRange(0, body.length, body);
    out.setRange(body.length, out.length, signature.bytes);
    return out;
  }

  /// Decode + verify. Throws [FormatException] on layout errors and
  /// [FormatException] (subclass) on signature failure.
  static Future<PeerAnnouncement> verifyAndDecode(Uint8List bytes) async {
    if (bytes.length < 1 + pubkeyLen * 3 + 1 + sigLen) {
      throw const FormatException('peer announcement truncated');
    }
    if (bytes[0] != version) {
      throw FormatException(
          'unknown peer announcement version 0x${bytes[0].toRadixString(16)}');
    }
    var c = 1;
    final pub = Uint8List.fromList(bytes.sublist(c, c += pubkeyLen));
    final signPub = Uint8List.fromList(bytes.sublist(c, c += pubkeyLen));
    final spk = Uint8List.fromList(bytes.sublist(c, c += pubkeyLen));
    final nlen = bytes[c++];
    if (bytes.length < c + nlen + sigLen) {
      throw const FormatException('peer announcement payload overrun');
    }
    final nameBytes = bytes.sublist(c, c + nlen);
    final name = utf8.decode(nameBytes, allowMalformed: true);
    c += nlen;
    final sig = bytes.sublist(c, c + sigLen);

    final body = bytes.sublist(0, c);
    final ok = await _ed25519.verify(
      body,
      signature: Signature(
        sig,
        publicKey: SimplePublicKey(signPub, type: KeyPairType.ed25519),
      ),
    );
    if (!ok) {
      throw const FormatException('peer announcement signature invalid');
    }
    return PeerAnnouncement(
      pubkey: pub,
      signPubkey: signPub,
      signedPrekeyPub: spk,
      nickname: name,
    );
  }

  Uint8List _encodeBody() {
    final nameBytes = utf8.encode(nickname);
    if (nameBytes.length > 255) {
      throw const FormatException('nickname > 255 UTF-8 bytes');
    }
    final out =
        Uint8List(1 + pubkeyLen * 3 + 1 + nameBytes.length);
    var c = 0;
    out[c++] = version;
    out.setRange(c, c += pubkeyLen, pubkey);
    out.setRange(c, c += pubkeyLen, signPubkey);
    out.setRange(c, c += pubkeyLen, signedPrekeyPub);
    out[c++] = nameBytes.length;
    out.setRange(c, c + nameBytes.length, nameBytes);
    return out;
  }
}
