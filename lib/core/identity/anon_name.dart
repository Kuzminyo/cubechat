import 'nickname_controller.dart';

/// Short, stable, pubkey-derived tag used to tell apart peers who never set a
/// nickname — without leaking anything about their device. It's the first two
/// bytes of the X25519 static pubkey (as hex): random, stable across restarts
/// and address rotation, and identical to what the peer advertises for itself.
String anonTag(String pubkeyHex) =>
    pubkeyHex.length >= 4 ? pubkeyHex.substring(0, 4) : pubkeyHex;

/// The name to show for a peer, resolving the anonymous default consistently.
///
/// A peer who set a real nickname is shown as-is. A peer on the default
/// nickname ('Anonymous') gets a pubkey tag appended — so two anonymous peers
/// are distinguishable, and the label matches what they broadcast in the
/// Nearby list. The whole point: never surface the OS device name (e.g.
/// 'Galaxy S24+') as an identity.
String displayNameForPeer(String rawName, String pubkeyHex) {
  final name = rawName.trim();
  if (name.isEmpty || name == NicknameController.defaultNickname) {
    return '${NicknameController.defaultNickname} ${anonTag(pubkeyHex)}';
  }
  return name;
}
