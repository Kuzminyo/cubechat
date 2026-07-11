import 'dart:convert';
import 'dart:typed_data';

/// Packs a cubechat [Frame] (the exact bytes the BLE mesh carries) into the
/// `content` field of a Nostr event, and back.
///
/// Design: Nostr is used purely as an **internet-side store-and-forward pipe
/// for cubechat's own encrypted frames** — not as a general Nostr client. The
/// frame is already end-to-end encrypted (SealedBox / X3DH) and signed
/// (SignedPayload), so the relay never sees plaintext. This codec only needs
/// to make the payload self-identifying so that:
///
///   * a cubechat peer sharing a public relay with unrelated Nostr traffic can
///     cheaply skip events that aren't ours, and
///   * a future wire-format bump is detectable (the scheme tag carries a
///     version).
///
/// Content format: `"cc1:" + base64(frameBytes)`.
///
/// The `cc1` prefix is the cubechat-frame-over-nostr scheme, version 1. In the
/// real NIP-17 integration the base64 blob is what gets gift-wrapped; this
/// codec is the innermost layer and stays stable across that change.
class NostrFrameCodec {
  NostrFrameCodec._();

  /// Scheme + version prefix on every cubechat event content.
  static const String scheme = 'cc1:';

  /// Wrap raw [frameBytes] into event content.
  static String encodeContent(Uint8List frameBytes) {
    return '$scheme${base64.encode(frameBytes)}';
  }

  /// Recover the frame bytes from event [content]. Returns null when the
  /// content is not a cubechat frame (wrong/missing scheme) or the base64 is
  /// malformed — callers treat null as "not for us, skip it" rather than an
  /// error, since a shared relay carries all kinds of traffic.
  static Uint8List? decodeContent(String content) {
    if (!content.startsWith(scheme)) return null;
    final b64 = content.substring(scheme.length);
    try {
      return base64.decode(b64);
    } on FormatException {
      return null;
    }
  }
}
