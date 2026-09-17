import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// "This device is running Pro", broadcast beside the peer announcement.
///
/// ## Why this is not a field in the announcement
///
/// [PeerAnnouncement] is versioned, and its decoder refuses a version it does
/// not know. Adding a byte there would mean emitting 0x06, and every phone
/// still on an older build would throw on it and drop the announcement whole —
/// no keys, no session, no messages. A badge is a decoration; making it cost
/// somebody their contacts is not a trade anyone would take.
///
/// A frame type is the safe seam instead. `Frame.decode` throws on a type it
/// does not know and [MessagingService] catches it, logs "drop malformed
/// frame" and carries on, so an older build ignores this and keeps working
/// exactly as it does today.
///
/// ## What the signature does and does not prove
///
/// It proves *who* is claiming, not that anybody paid. Stage one keeps the
/// store receipt on the device, so a modified build can assert this about
/// itself and nothing here can tell. What the signature buys is that a relay
/// on the path cannot pin the claim on somebody else, or strip it off them.
/// Proof of payment needs the blind-signed tokens of stage two.
///
/// ## Cost
///
/// Only sent while Pro is actually on. A device without it emits nothing extra,
/// which matters on a beacon cadence that has already been tuned twice for
/// heat.
///
/// Wire layout (inside a [FrameType.proBadge] frame):
///
/// ```
///   [version  :  1 byte = 0x01]
///   [ed25519  : 32 bytes — the identity making the claim]
///   [flags    :  1 byte  — bit 0: Pro is on]
///   [sig      : 64 bytes — Ed25519 over everything above]
/// ```
class ProBadge {
  const ProBadge({required this.signPubkey, required this.isPro});

  /// The Ed25519 verifying key of whoever is claiming.
  final Uint8List signPubkey;

  final bool isPro;

  static const int version = 0x01;
  static const int pubkeyLen = 32;
  static const int sigLen = 64;

  /// version + pubkey + flags.
  static const int bodyLen = 1 + pubkeyLen + 1;
  static const int totalLen = bodyLen + sigLen;

  static const int _flagPro = 0x01;

  static final _ed25519 = Ed25519();

  /// Build and sign one.
  static Future<Uint8List> signed({
    required SimpleKeyPair keyPair,
    required bool isPro,
  }) async {
    final pub = await keyPair.extractPublicKey();
    final body = Uint8List(bodyLen);
    var c = 0;
    body[c++] = version;
    body.setRange(c, c += pubkeyLen, pub.bytes);
    body[c++] = isPro ? _flagPro : 0x00;

    final sig = await _ed25519.sign(body, keyPair: keyPair);
    final out = Uint8List(totalLen);
    out.setRange(0, bodyLen, body);
    out.setRange(bodyLen, totalLen, sig.bytes);
    return out;
  }

  /// Decode and verify. Throws [FormatException] on a bad layout, an unknown
  /// version, or a signature that does not check out.
  static Future<ProBadge> verifyAndDecode(Uint8List bytes) async {
    if (bytes.length != totalLen) {
      throw const FormatException('pro badge is the wrong length');
    }
    if (bytes[0] != version) {
      throw FormatException(
        'unknown pro badge version 0x${bytes[0].toRadixString(16)}',
      );
    }
    final signPub = Uint8List.sublistView(bytes, 1, 1 + pubkeyLen);
    final flags = bytes[1 + pubkeyLen];
    final body = Uint8List.sublistView(bytes, 0, bodyLen);
    final sig = Uint8List.sublistView(bytes, bodyLen, totalLen);

    final ok = await _ed25519.verify(
      body,
      signature: Signature(
        sig,
        publicKey: SimplePublicKey(signPub, type: KeyPairType.ed25519),
      ),
    );
    if (!ok) {
      throw const FormatException('pro badge signature invalid');
    }
    return ProBadge(
      signPubkey: Uint8List.fromList(signPub),
      isPro: flags & _flagPro != 0,
    );
  }
}
