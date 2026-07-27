import 'dart:convert';
import 'dart:typed_data';

import 'announcement.dart';

/// A shareable identity card — the bootstrap for talking to someone you have
/// **never met over BLE**.
///
/// Everything cubechat needs to reach a peer already exists in one place: the
/// signed [PeerAnnouncement] (v0x04), which binds their X25519 static key,
/// Ed25519 verifying key, signed prekey, Nostr pubkey and nickname under one
/// Ed25519 signature. On the mesh that bundle travels as a broadcast frame. The
/// only thing missing for an off-mesh first contact was a way to hand the same
/// bundle to someone out of radio range — so that is exactly what a card is:
/// the announcement bytes, verbatim, in a form you can paste into any other
/// messenger or put in a QR code.
///
/// ```
///   cubechat:c1:<base64url(signedAnnouncementBytes)>
/// ```
///
/// Reusing the announcement wholesale is deliberate. There is no second wire
/// format to keep in sync, no new signing context, and [parse] is the *same*
/// [PeerAnnouncement.verifyAndDecode] gate a mesh announcement goes through —
/// a card whose bytes were edited in transit fails the Ed25519 check and is
/// rejected before it can reach the roster.
///
/// **What a card does not give you.** The signature proves the bundle is
/// internally consistent and unmodified; it does not prove *who handed it to
/// you*. Anyone can mint a card for their own keys and claim any nickname, and
/// a card forwarded through a chat app could have been swapped by whoever
/// carried it. So a peer added this way starts unverified — compare
/// fingerprints out of band (the verification screen) before treating the
/// identity as confirmed.
class ContactCard {
  ContactCard._();

  /// Scheme + version prefix. `c1` is contact-card v1; the payload is a v0x04
  /// signed announcement.
  static const String scheme = 'cubechat:c1:';

  /// Alternate spelling accepted on input — some chat apps only linkify (and
  /// therefore only make tappable/copyable in one piece) an `://` URI.
  static const String uriScheme = 'cubechat://c1/';

  /// Wrap already-signed announcement bytes into a card string.
  static String encode(Uint8List signedAnnouncement) =>
      '$scheme${_base64UrlNoPad(signedAnnouncement)}';

  /// Pull the card token out of arbitrary pasted text and decode it to raw
  /// announcement bytes. Returns null when [raw] holds nothing card-shaped.
  ///
  /// Deliberately forgiving, because the text arrives via whatever the two
  /// people happened to use: it tolerates surrounding words, either scheme
  /// spelling, line breaks injected by a mail client, and missing base64
  /// padding. It is *not* forgiving about content — malformed bytes and bad
  /// signatures are still rejected downstream by [parse].
  static Uint8List? tryDecodeBytes(String raw) {
    final token = _extractToken(raw);
    if (token == null || token.isEmpty) return null;
    try {
      return base64.decode(base64.normalize(token));
    } on FormatException {
      return null;
    }
  }

  /// Decode **and cryptographically verify** a pasted card.
  ///
  /// Throws [FormatException] when the text carries no card, when the bytes
  /// aren't a well-formed announcement, or when the Ed25519 signature doesn't
  /// match the keys it commits to.
  static Future<PeerAnnouncement> parse(String raw) async {
    final bytes = tryDecodeBytes(raw);
    if (bytes == null) {
      throw const FormatException('not a cubechat contact card');
    }
    return PeerAnnouncement.verifyAndDecode(bytes);
  }

  /// True when [raw] contains something that at least *looks* like a card —
  /// used to light up a paste button without paying for signature verification
  /// on every keystroke.
  static bool looksLikeCard(String raw) => _extractToken(raw) != null;

  /// Find the base64 token, with or without a scheme prefix.
  static String? _extractToken(String raw) {
    final compact = raw.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return null;

    for (final prefix in const [scheme, uriScheme]) {
      final at = compact.indexOf(prefix);
      if (at >= 0) {
        final rest = compact.substring(at + prefix.length);
        final token = _leadingBase64(rest);
        return token.isEmpty ? null : token;
      }
    }

    // No prefix survived the round trip (some clients rewrite unknown schemes).
    // Accept a bare token only when the whole string is base64 and long enough
    // to plausibly hold an announcement — the signature check is the real gate.
    if (_isAllBase64(compact) && compact.length >= _minTokenChars) {
      return compact;
    }
    return null;
  }

  /// A signed announcement is at minimum version(1) + four 32-byte keys +
  /// nameLen(1) + signature(64) = 194 bytes, which is 259 base64 characters.
  static const int _minTokenChars = 259;

  static String _leadingBase64(String s) {
    var end = 0;
    while (end < s.length && _isBase64Char(s.codeUnitAt(end))) {
      end++;
    }
    return s.substring(0, end);
  }

  static bool _isAllBase64(String s) {
    for (var i = 0; i < s.length; i++) {
      if (!_isBase64Char(s.codeUnitAt(i))) return false;
    }
    return true;
  }

  /// Both base64 alphabets plus padding — [base64.normalize] folds `-_` into
  /// `+/` and restores the `=`, so we accept the union here.
  static bool _isBase64Char(int c) {
    return (c >= 0x41 && c <= 0x5A) || // A-Z
        (c >= 0x61 && c <= 0x7A) || // a-z
        (c >= 0x30 && c <= 0x39) || // 0-9
        c == 0x2B || // +
        c == 0x2F || // /
        c == 0x2D || // -
        c == 0x5F || // _
        c == 0x3D; // =
  }

  static String _base64UrlNoPad(Uint8List bytes) {
    final s = base64Url.encode(bytes);
    var end = s.length;
    while (end > 0 && s.codeUnitAt(end - 1) == 0x3D) {
      end--;
    }
    return s.substring(0, end);
  }
}
