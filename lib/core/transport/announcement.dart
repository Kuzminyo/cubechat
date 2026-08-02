import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Self-authenticating "I am here" payload broadcast over the mesh.
///
/// Wire layout (lives inside a [TransportEnvelope] with `dest = broadcast`,
/// wrapped in a [FrameType.peerAnnouncement] frame):
///
/// ```
///   [version  :  1 byte = 0x05]
///   [x25519   : 32 bytes — Curve25519 static (encryption + routing identity)]
///   [ed25519  : 32 bytes — Ed25519 verifying key (message signatures)]
///   [spk      : 32 bytes — X25519 signed prekey (forward-secret messaging)]
///   [npub     : 32 bytes — x-only secp256k1 Nostr pubkey (M6 off-mesh reach)]
///   [nameLen  :  1 byte]
///   [name     : nameLen bytes UTF-8]
///   [avatar   : 32 bytes — SHA-256 of the sender's avatar thumbnail; v0x05+,
///                          all-zero when they have no picture]
///   [sig      : 64 bytes — Ed25519 over everything above]
/// ```
///
/// The signature locks the (x25519_pub ↔ ed25519_pub ↔ spk ↔ npub ↔ nickname)
/// binding so Mallory can't announce "I am Alice's X25519 hash" with their
/// own keys — any forgery attempt would need Alice's Ed25519 private key.
/// Receivers verify the sig, then cache the bundle (incl. the signed prekey
/// and the Nostr pubkey) in KnownPeers; senders use the cached SPK to open a
/// forward-secret X3DH session and the cached npub to reach the peer over
/// Nostr when the mesh can't.
///
/// The [nostrPubkey] is the peer's deterministically-derived secp256k1 key
/// (see `Secp256k1NostrSigner`); it is signed into the announcement so it
/// inherits the same authenticity guarantee as the rest of the identity
/// bundle — a relay can't swap in its own Nostr address to intercept the
/// off-mesh fallback.
class PeerAnnouncement {
  PeerAnnouncement({
    required this.pubkey,
    required this.signPubkey,
    required this.signedPrekeyPub,
    required this.nostrPubkey,
    required this.nickname,
    this.avatarHash,
    this.isAvatarAware = true,
  })  : assert(pubkey.length == pubkeyLen, 'pubkey must be $pubkeyLen B'),
        assert(avatarHash == null || avatarHash.length == avatarHashLen,
            'avatarHash must be $avatarHashLen B'),
        assert(signPubkey.length == pubkeyLen,
            'signPubkey must be $pubkeyLen B'),
        assert(signedPrekeyPub.length == pubkeyLen,
            'signedPrekeyPub must be $pubkeyLen B'),
        assert(nostrPubkey.length == pubkeyLen,
            'nostrPubkey must be $pubkeyLen B');

  /// X25519 long-term encryption key.
  final Uint8List pubkey;

  /// Ed25519 long-term verifying key.
  final Uint8List signPubkey;

  /// X25519 signed prekey — the recipient-side half of forward-secret X3DH.
  final Uint8List signedPrekeyPub;

  /// x-only (32-byte) secp256k1 Nostr public key — where this peer can be
  /// reached over public Nostr relays when they're out of BLE range (M6).
  final Uint8List nostrPubkey;

  final String nickname;

  /// SHA-256 of the sender's avatar thumbnail, or null when they have no
  /// picture (and for a v0x04 peer, which had no field to put one in).
  ///
  /// Only the *hash* rides here. The picture itself is a few kilobytes — far
  /// too much for something broadcast on a heartbeat to every peer in range,
  /// most of whom already have it. Carrying the digest instead lets a receiver
  /// notice a change and ask for the bytes once, and because it sits inside the
  /// signed body it also pins them: a relay handing over a different picture
  /// fails the check against a hash it cannot forge.
  final Uint8List? avatarHash;

  /// Whether the sender's build has an avatar field at all (v0x05+).
  ///
  /// Distinguishes "I have no picture" from "I cannot say", which look
  /// identical in [avatarHash] and must not: reading a v0x04 peer's silence as
  /// a removal would delete a picture we hold every time one of their
  /// announcements arrived.
  final bool isAvatarAware;

  /// Wire version this build emits. v0x04 is still accepted on decode — see
  /// [verifyAndDecode] — so a peer who hasn't updated keeps working, minus the
  /// avatar.
  static const int version = 0x05;
  static const int versionV4NoAvatar = 0x04;
  static const int pubkeyLen = 32;
  static const int sigLen = 64;
  static const int avatarHashLen = 32;

  /// All-zero stands for "no picture" so the field is fixed-width: a length
  /// byte would be one more thing for a sender to lie about, and the digest of
  /// real bytes is never all zeros.
  static final Uint8List noAvatar = Uint8List(avatarHashLen);

  static bool _isZero(Uint8List b) {
    for (final byte in b) {
      if (byte != 0) return false;
    }
    return true;
  }

  /// Number of fixed-size 32-byte key fields (x25519, ed25519, spk, npub).
  static const int _keyFields = 4;

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
    if (bytes.length < 1 + pubkeyLen * _keyFields + 1 + sigLen) {
      throw const FormatException('peer announcement truncated');
    }
    // v0x04 is the same layout minus the avatar digest. Accepted rather than
    // rejected: a peer on an older build should keep appearing in the roster
    // with their name and keys intact — they simply have no picture to offer.
    final ver = bytes[0];
    if (ver != version && ver != versionV4NoAvatar) {
      throw FormatException(
          'unknown peer announcement version 0x${ver.toRadixString(16)}');
    }
    final hasAvatar = ver == version;
    var c = 1;
    final pub = Uint8List.fromList(bytes.sublist(c, c += pubkeyLen));
    final signPub = Uint8List.fromList(bytes.sublist(c, c += pubkeyLen));
    final spk = Uint8List.fromList(bytes.sublist(c, c += pubkeyLen));
    final npub = Uint8List.fromList(bytes.sublist(c, c += pubkeyLen));
    final nlen = bytes[c++];
    final avatarBytes = hasAvatar ? avatarHashLen : 0;
    if (bytes.length < c + nlen + avatarBytes + sigLen) {
      throw const FormatException('peer announcement payload overrun');
    }
    final nameBytes = bytes.sublist(c, c + nlen);
    final name = utf8.decode(nameBytes, allowMalformed: true);
    c += nlen;
    Uint8List? avatar;
    if (hasAvatar) {
      final raw = Uint8List.fromList(bytes.sublist(c, c += avatarHashLen));
      // All-zero is "no picture", which is a null here rather than a digest
      // nothing will ever match.
      avatar = _isZero(raw) ? null : raw;
    }
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
      nostrPubkey: npub,
      nickname: name,
      avatarHash: avatar,
      isAvatarAware: hasAvatar,
    );
  }

  Uint8List _encodeBody() {
    final nameBytes = utf8.encode(nickname);
    if (nameBytes.length > 255) {
      throw const FormatException('nickname > 255 UTF-8 bytes');
    }
    final out = Uint8List(
      1 + pubkeyLen * _keyFields + 1 + nameBytes.length + avatarHashLen,
    );
    var c = 0;
    out[c++] = version;
    out.setRange(c, c += pubkeyLen, pubkey);
    out.setRange(c, c += pubkeyLen, signPubkey);
    out.setRange(c, c += pubkeyLen, signedPrekeyPub);
    out.setRange(c, c += pubkeyLen, nostrPubkey);
    out[c++] = nameBytes.length;
    out.setRange(c, c += nameBytes.length, nameBytes);
    out.setRange(c, c += avatarHashLen, avatarHash ?? noAvatar);
    return out;
  }
}
