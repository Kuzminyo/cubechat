import 'dart:convert';

/// A lightweight contact reference that can travel as an ordinary encrypted
/// text message. New clients render it as a contact card; older clients keep a
/// harmless opaque token instead of failing to decode the conversation.
class SharedContact {
  const SharedContact({
    required this.pubkeyHex,
    required this.displayName,
    this.invitedMemberId,
    this.card,
  });

  static const _prefix = 'cubechat:contact:v1:';

  final String pubkeyHex;
  final String displayName;

  /// The room member this card was offered to, by the sixteen hex characters a
  /// channel frame reveals of their signing key.
  ///
  /// Set when the card is an invitation rather than a share. The direction is
  /// the only one a room allows: a channel frame carries its author's
  /// *fingerprint*, never their public key, so nobody can add a member from
  /// what the room shows — the member has to be handed a card and add the
  /// sender. "Invite them to be friends" therefore means "offer them mine",
  /// and this field is who it was offered to, so their app can say the
  /// invitation is theirs and everyone else's can stay quiet about it.
  final String? invitedMemberId;

  /// The sender's full signed contact card, when this is an invitation.
  ///
  /// The pubkey above is enough to *name* somebody the app already knows; it
  /// is not enough to reach a stranger, who has no announcement of ours on
  /// file and no prekey to encrypt to. An invitation crosses exactly that gap,
  /// so it carries the whole card — the same one the Profile screen shows as a
  /// QR — and the receiving app imports it, after which the sender is an
  /// ordinary contact.
  final String? card;

  bool get isInvitation => invitedMemberId != null;

  String encode() {
    final payload = jsonEncode({
      'id': pubkeyHex,
      'name': displayName,
      // Left out entirely when absent: an older build reads the two keys it
      // knows and ignores the rest, so an ordinary share stays byte-identical
      // to what it always was.
      if (invitedMemberId != null) 'to': invitedMemberId,
      if (card != null) 'card': card,
    });
    return '$_prefix${base64Url.encode(utf8.encode(payload)).replaceAll('=', '')}';
  }

  static SharedContact? tryParse(String raw) {
    final value = raw.trim();
    if (!value.startsWith(_prefix)) return null;
    try {
      final token = value.substring(_prefix.length);
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(token))),
      );
      if (decoded is! Map) return null;
      final id = decoded['id'];
      final name = decoded['name'];
      if (id is! String ||
          name is! String ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(id) ||
          name.trim().isEmpty) {
        return null;
      }
      final to = decoded['to'];
      final card = decoded['card'];
      return SharedContact(
        pubkeyHex: id.toLowerCase(),
        displayName: name.trim(),
        invitedMemberId: to is String && RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(to)
            ? to.toLowerCase()
            : null,
        card: card is String && card.isNotEmpty ? card : null,
      );
    } on Object {
      return null;
    }
  }
}
