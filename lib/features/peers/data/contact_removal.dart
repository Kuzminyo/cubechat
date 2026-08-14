import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/data/conversation_settings_controller.dart';
import '../../chat/data/drafts_controller.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/data/pinned_controller.dart';
import '../../chats/data/favorites_controller.dart';
import '../../chats/data/hidden_chats_controller.dart';
import '../../chats/data/pinned_chats_controller.dart';
import '../../chats/data/read_markers_controller.dart';
import '../../chats/data/user_chat_folders_controller.dart';
import 'contact_aliases_controller.dart';
import 'known_peers_controller.dart';
import 'peer_avatars_controller.dart';

/// Forget a person and everything of theirs this phone is holding.
///
/// One function rather than a copy per screen. Deleting a contact used to take
/// the roster entry and the settings while the conversation itself, the name
/// you gave them, their place in your folders and the pin holding them at the
/// top of the list all stayed — so the contact came back on the next screen you
/// opened, wearing the alias you had given them. Every screen that offers to
/// delete somebody now removes the same eleven things, because there is only
/// one list of them.
///
/// The confirmation is the caller's: this asks nothing and undoes nothing.
Future<void> forgetContactEverywhere(WidgetRef ref, String pubkeyHex) async {
  await ref.read(knownPeersControllerProvider.notifier).forget(pubkeyHex);
  await ref.read(peerAvatarsControllerProvider.notifier).forget(pubkeyHex);
  await ref
      .read(conversationSettingsControllerProvider.notifier)
      .forget(pubkeyHex);
  await ref.read(favoritesControllerProvider.notifier).forget(pubkeyHex);
  await ref.read(pinnedControllerProvider.notifier).forget(pubkeyHex);
  await ref.read(draftsControllerProvider.notifier).clear(pubkeyHex);
  await ref.read(messagesControllerProvider.notifier).clearForChat(pubkeyHex);
  await ref.read(readMarkersControllerProvider.notifier).forget(pubkeyHex);
  await ref.read(contactAliasesControllerProvider.notifier).clearAlias(pubkeyHex);
  await ref.read(pinnedChatsControllerProvider.notifier).forget(pubkeyHex);
  // Not "hide" — the person is gone, so there is no tile left to suppress, and
  // a stale entry here would hide the next conversation with somebody whose key
  // happens to come back (a contact re-added from the same card).
  await ref.read(hiddenChatsControllerProvider.notifier).unhide(pubkeyHex);
  await ref.read(userChatFoldersControllerProvider.notifier).forgetChat(pubkeyHex);
}
