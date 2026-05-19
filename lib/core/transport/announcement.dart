import 'dart:convert';
import 'dart:typed_data';

/// Plain-text "I am here" payload carried inside a [TransportEnvelope] with
/// `dest = broadcast`. Receivers register the (pubkey, nickname) pair into
/// their KnownPeers roster so the user sees mesh-only peers in the Chats
/// list even before a direct Noise session is established.
///
/// Layout:
///
/// ```
///   [version : 1 byte = 0x01]
///   [pubkey  : 32 bytes — Curve25519 static]
///   [nameLen : 1 byte]
///   [name    : nameLen bytes UTF-8]
/// ```
///
/// The payload is intentionally unencrypted — relays without a session to
/// the origin must still be able to forward it (M3.E). Spoofing the
/// nickname is possible (Mallory can announce "Alice" with Mallory's own
/// pubkey), but the identity root is the pubkey, not the label.
class PeerAnnouncement {
  PeerAnnouncement({
    required this.pubkey,
    required this.nickname,
  }) : assert(pubkey.length == pubkeyLen, 'pubkey must be $pubkeyLen B');

  final Uint8List pubkey;
  final String nickname;

  static const int version = 0x01;
  static const int pubkeyLen = 32;

  Uint8List encode() {
    final nameBytes = utf8.encode(nickname);
    if (nameBytes.length > 255) {
      throw const FormatException('nickname > 255 UTF-8 bytes');
    }
    final out = Uint8List(1 + pubkeyLen + 1 + nameBytes.length);
    var c = 0;
    out[c++] = version;
    out.setRange(c, c += pubkeyLen, pubkey);
    out[c++] = nameBytes.length;
    out.setRange(c, c + nameBytes.length, nameBytes);
    return out;
  }

  static PeerAnnouncement decode(Uint8List bytes) {
    if (bytes.length < 1 + pubkeyLen + 1) {
      throw const FormatException('peer announcement truncated');
    }
    if (bytes[0] != version) {
      throw FormatException(
          'unknown peer announcement version 0x${bytes[0].toRadixString(16)}');
    }
    var c = 1;
    final pub = Uint8List.fromList(bytes.sublist(c, c += pubkeyLen));
    final nlen = bytes[c++];
    if (bytes.length < c + nlen) {
      throw const FormatException('peer announcement nickname overrun');
    }
    final name = utf8.decode(
      bytes.sublist(c, c + nlen),
      allowMalformed: true,
    );
    return PeerAnnouncement(pubkey: pub, nickname: name);
  }
}
