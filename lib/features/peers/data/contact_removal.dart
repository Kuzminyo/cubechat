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
import 'removed_contacts_controller.dart';

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
  // Every notifier resolved before the first await, and none reached for
  // through `ref` after one.
  //
  // `ref` belongs to the screen that offered the delete — a contact profile,
  // or a row in a list — and the very first step removes the person that
  // screen is about, so it can be gone before the second step runs. Anything
  // after the throw was skipped, which left a contact forgotten from the
  // roster and still holding their alias, their avatar and their messages.
  final known = ref.read(knownPeersControllerProvider.notifier);
  final removed = ref.read(removedContactsControllerProvider.notifier);
  final avatars = ref.read(peerAvatarsControllerProvider.notifier);
  final settings = ref.read(conversationSettingsControllerProvider.notifier);
  final favorites = ref.read(favoritesControllerProvider.notifier);
  final pinned = ref.read(pinnedControllerProvider.notifier);
  final drafts = ref.read(draftsControllerProvider.notifier);
  final messages = ref.read(messagesControllerProvider.notifier);
  final readMarkers = ref.read(readMarkersControllerProvider.notifier);
  final aliases = ref.read(contactAliasesControllerProvider.notifier);
  final pinnedChats = ref.read(pinnedChatsControllerProvider.notifier);
  final hidden = ref.read(hiddenChatsControllerProvider.notifier);
  final folders = ref.read(userChatFoldersControllerProvider.notifier);

  // First, so that nothing arriving mid-removal can put them back before the
  // rest of it has run.
  await removed.remember(pubkeyHex);
  await known.forget(pubkeyHex);
  await avatars.forget(pubkeyHex);
  await settings.forget(pubkeyHex);
  await favorites.forget(pubkeyHex);
  await pinned.forget(pubkeyHex);
  await drafts.clear(pubkeyHex);
  await messages.clearForChat(pubkeyHex);
  await readMarkers.forget(pubkeyHex);
  await aliases.clearAlias(pubkeyHex);
  await pinnedChats.forget(pubkeyHex);
  // Not "hide" — the person is gone, so there is no tile left to suppress, and
  // a stale entry here would hide the next conversation with somebody whose key
  // happens to come back (a contact re-added from the same card).
  await hidden.unhide(pubkeyHex);
  await folders.forgetChat(pubkeyHex);
}
