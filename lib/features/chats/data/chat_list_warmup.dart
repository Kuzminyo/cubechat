import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../channels/data/channel_controller.dart';
import '../../chat/data/conversation_settings_controller.dart';
import '../../chat/data/drafts_controller.dart';
import '../../chat/data/messages_controller.dart';
import '../../peers/data/contact_aliases_controller.dart';
import '../../peers/data/known_peers_controller.dart';
import 'archived_chats_controller.dart';
import 'chat_folders_controller.dart';
import 'favorites_controller.dart';
import 'hidden_chats_controller.dart';
import 'pinned_chats_controller.dart';
import 'read_markers_controller.dart';

/// Read everything the chat list is made of, before the first frame draws it.
///
/// The list used to arrive in two pieces. Every controller behind it returns an
/// empty collection from `build()` and fills it from disk afterwards, so the
/// first frame was a chat list with no chats in it — which is not a blank
/// moment but a wrong one: `filtered.isEmpty` renders the *empty state*, so a
/// phone with a hundred conversations opened on "no chats yet".
///
/// Then the boxes landed and the rows appeared. Without an entrance, too:
/// [AppearOnce] turns the row animation off in a post-frame callback, and by
/// the time the rows existed that callback had long since run. So the rows did
/// not arrive, they replaced — a hard cut from one screenful to another, which
/// is exactly how it was described, twice, as a jerk on startup.
///
/// Waiting here costs nothing visible. Before the first frame the platform is
/// still showing the launch icon, so this time is spent behind an image the
/// user is already looking at, instead of in front of a screen that is telling
/// them something untrue.
///
/// Everything the list reads is waited on, and each of them is waited on by its
/// own `loaded` future rather than by any argument about timing. Five of these
/// controllers had no such future until this existed; giving them one turned up
/// a separate bug they all shared, which is written up above their `_persist`.
///
/// The waits are concurrent, so this costs the slowest read and not the sum.
/// Most of them share the settings box, which is opened once for all of them.
///
/// Nothing here is allowed to be slow. The caller runs it under a timeout — a
/// list that arrives late is the old behaviour, which is survivable, and a
/// launch icon that never goes away is not.
Future<void> warmChatList(ProviderContainer container) async {
  // Reading a notifier is what constructs it, and constructing it is what
  // starts its read. So this line is the work beginning, not a query about it.
  await Future.wait(<Future<void>>[
    container.read(messagesControllerProvider.notifier).loaded,
    container.read(knownPeersControllerProvider.notifier).loaded,
    container.read(channelControllerProvider.notifier).loaded,
    container.read(contactAliasesControllerProvider.notifier).loaded,
    container.read(conversationSettingsControllerProvider.notifier).loaded,
    container.read(readMarkersControllerProvider.notifier).loaded,
    container.read(draftsControllerProvider.notifier).loaded,
    container.read(pinnedChatsControllerProvider.notifier).loaded,
    container.read(archivedChatsControllerProvider.notifier).loaded,
    container.read(hiddenChatsControllerProvider.notifier).loaded,
    container.read(chatFoldersControllerProvider.notifier).loaded,
    container.read(favoritesControllerProvider.notifier).loaded,
  ]);
}
