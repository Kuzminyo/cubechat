import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/identity/anon_name.dart';
import '../../../../core/identity/nickname_controller.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../peers/data/contact_aliases_controller.dart';
import '../../../peers/data/known_peers_controller.dart';
import '../../models/message.dart';

String playbackAuthor(
  BuildContext context,
  WidgetRef ref,
  Message message, {
  String? chatId,
  String? chatTitle,
}) {
  if (message.isMine) {
    final mine = ref.read(nicknameControllerProvider).trim();
    if (mine.isNotEmpty) return mine;
    return AppLocalizations.of(context).chatReplyYou;
  }
  final author = message.authorName?.trim();
  if (author != null && author.isNotEmpty) return author;
  final peers = ref.read(knownPeersControllerProvider);
  // The rendered bucket first, the message's own id second: the former is
  // the canonical pubkey wherever the caller knows it, the latter is only
  // right for a message that came in over the relay.
  final peer = peers[chatId ?? ''] ?? peers[message.chatId];
  if (peer != null) {
    return contactDisplayName(
      alias: ref.read(contactAliasesControllerProvider)[peer.pubkeyHex],
      rawBroadcastName: peer.displayName,
      pubkeyHex: peer.pubkeyHex,
    );
  }
  final given = chatTitle?.trim();
  if (given != null && given.isNotEmpty) return given;
  return AppLocalizations.of(context).bleUnknownPeer;
}
