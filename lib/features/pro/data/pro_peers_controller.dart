import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../peers/data/known_peers_controller.dart';

/// Which peers have said they are running Pro, by Ed25519 verifying key.
///
/// Held in memory and nowhere else, deliberately. A badge is presence
/// information: it arrives with a beacon, it is true for as long as that device
/// is around saying so, and writing it to disk would turn a decoration into a
/// record of who paid, kept on somebody else's phone across restarts.
///
/// The claim is signed by the identity making it — see `ProBadge` — so it
/// cannot be pinned on anyone else. It is still a claim and not a proof: the
/// stage-one receipt lives on the claiming device, so a modified build can
/// assert it. Nothing in the interface should promise more than "they say so".
class ProPeersController extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  /// [signPubkeyHex] is the peer's Ed25519 verifying key, lower-case hex.
  void setPro(String signPubkeyHex, {required bool isPro}) {
    final has = state.contains(signPubkeyHex);
    if (has == isPro) return;
    final next = {...state};
    if (isPro) {
      next.add(signPubkeyHex);
    } else {
      next.remove(signPubkeyHex);
    }
    state = next;
  }

  bool isPro(String signPubkeyHex) => state.contains(signPubkeyHex);
}

final proPeersProvider =
    NotifierProvider<ProPeersController, Set<String>>(ProPeersController.new);

/// Does the peer of this chat claim Pro?
///
/// The badge is signed by an Ed25519 key and a chat is keyed by an X25519 one,
/// so the two are joined here through the bundle the announcement already
/// cached. Doing it at this end rather than at ingest means a badge that
/// arrives before its announcement is not thrown away for want of a peer we
/// are about to learn about.
final peerClaimsProProvider = Provider.family<bool, String>((ref, chatId) {
  final claimed = ref.watch(proPeersProvider);
  if (claimed.isEmpty) return false;
  final sign = ref.watch(knownPeersControllerProvider)[chatId]?.signPublicKey;
  if (sign == null) return false;
  return claimed.contains(_hex(sign));
});

String _hex(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
