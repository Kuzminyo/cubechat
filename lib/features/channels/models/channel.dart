import 'package:flutter/foundation.dart';

/// A shared-key group channel the user has joined.
///
/// Everything needed to send and receive lives here: the [key] encrypts and
/// decrypts every channel message, and the [tag] is the public selector sent
/// in the clear so a receiver can pick the right channel without trial
/// decryption. See `ChannelCrypto` for how both are derived from
/// ([name], password).
@immutable
class Channel {
  const Channel({
    required this.name,
    required this.hasPassword,
    required this.key,
    required this.tag,
    required this.joinedAt,
    this.viaInvite = false,
  });

  /// Human channel id, including the leading `#` (e.g. `#general`). Also used
  /// as the chat id / message-bucket key, so it doubles as the routing key in
  /// the UI. Normalised to lower-case with no whitespace by
  /// [normalizeChannelName].
  final String name;

  /// Whether a non-empty password went into the key derivation. Purely
  /// cosmetic (a lock icon in the UI) — the key already bakes it in.
  final bool hasPassword;

  /// 32-byte ChaCha20-Poly1305 key.
  final Uint8List key;

  /// 8-byte public selector derived one-way from [key].
  final Uint8List tag;

  final DateTime joinedAt;

  /// Whether we got here from somebody else's invitation.
  ///
  /// The one thing this protocol can actually establish about seniority. There
  /// is no server and no creation event: joining is deriving a key from a name
  /// and a password, so the person who invents a room and the person who types
  /// the same name an hour later run identical code and are indistinguishable.
  /// An invitation is different — it can only have come from somebody who was
  /// already there, so an invitee is definitively *not* the room's first
  /// member, and that is enough to keep them from claiming it.
  ///
  /// Used by [ChannelRosterController.ensureSelf] to decide whether joining may
  /// claim the admin seat when the room has nobody in it yet.
  final bool viaInvite;
}

/// Canonical form of a channel name: lower-case, a single leading `#`, and no
/// internal whitespace (spaces would otherwise let `#foo bar` and `#foo-bar`
/// derive different keys for what a user typed as "the same" room). Returns
/// an empty string for input that is nothing but `#`/whitespace.
String normalizeChannelName(String raw) {
  var n = raw.trim().toLowerCase();
  n = n.replaceAll(RegExp(r'^#+'), '');
  n = n.replaceAll(RegExp(r'\s+'), '-');
  if (n.isEmpty) return '';
  return '#$n';
}
