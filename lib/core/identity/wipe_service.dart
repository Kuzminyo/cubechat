import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/channels/data/channel_controller.dart';
import '../../features/channels/data/channel_roster_controller.dart';
import '../../features/chat/data/messages_controller.dart';
import '../../features/chat/data/drafts_controller.dart';
import '../../features/files/data/file_transfer_controller.dart';
import '../../features/chat/data/pinned_controller.dart';
import '../../features/chat/data/reaction_emoji_controller.dart';
import '../../features/chats/data/chat_folders_controller.dart';
import '../../features/chats/data/favorites_controller.dart';
import '../../features/chats/data/pinned_chats_controller.dart';
import '../../features/chats/data/hidden_chats_controller.dart';
import '../../features/chat/data/conversation_settings_controller.dart';
import '../../features/chats/data/read_markers_controller.dart';
import '../../features/chats/data/recent_searches_controller.dart';
import '../../features/chats/data/user_chat_folders_controller.dart';
import '../../features/map/data/map_friends_controller.dart';
import '../../features/map/data/shared_map_locations_provider.dart';
import '../../features/peers/data/known_peers_controller.dart';
import '../../features/channels/data/channel_avatars_controller.dart';
import '../../features/channels/data/channel_descriptions_controller.dart';
import '../../features/peers/data/contact_aliases_controller.dart';
import '../../features/peers/data/peer_avatars_controller.dart';
import '../../features/onboarding/data/onboarding_controller.dart';
import '../../features/peers/data/typing_controller.dart';
import '../../features/peers/data/presence_controller.dart';
import 'avatar_controller.dart';
import '../theme/theme_controller.dart';
import '../../features/profile/data/discovery_settings_controller.dart';
import '../../features/profile/data/privacy_settings_controller.dart';
import '../../features/profile/data/relay_settings_controller.dart';
import '../../features/profile/data/ui_scale_controller.dart';
import '../crypto/identity_service.dart';
import '../crypto/prekey_service.dart';
import '../storage/hive_cipher.dart';
import '../storage/hive_init.dart';
import '../util/media_storage.dart';
import '../transport/chat_session_manager.dart';
import '../transport/messaging_service.dart';
import 'nickname_controller.dart';

/// Emergency wipe.
///
/// Drops every byte of cubechat state on this device:
/// - In-memory: messages, known peers, nickname, every live Noise session
/// - On disk:   all Hive boxes (messages, known peers, settings)
/// - Secure:    the X25519 identity private key + the Hive AES key in
///              Keychain / Keystore
///
/// After this call, opening the app again is indistinguishable from a fresh
/// install — a brand new identity gets minted on first read of
/// identityProvider, and chats list is empty.
Future<void> emergencyWipe(WidgetRef ref) async {
  // Remembered "does this file exist" answers, which outlive the rows that
  // asked. Cheap to drop and wrong to keep: a wipe must not leave anything
  // still saying yes about a photo it just deleted.
  MediaPaths.forgetAll();
  // 1. In-memory state first so nothing tries to re-persist mid-wipe.
  await ref.read(messagesControllerProvider.notifier).clearAll();
  await ref.read(knownPeersControllerProvider.notifier).clear();
  // Other people's pictures are other people's data, and they live in their own
  // box — clearing the roster does not reach them.
  await ref.read(peerAvatarsControllerProvider.notifier).clear();
  // What you called people is as much your data as who they are.
  await ref.read(contactAliasesControllerProvider.notifier).clear();
  await ref.read(channelAvatarsControllerProvider.notifier).clear();
  await ref.read(channelDescriptionsControllerProvider.notifier).clear();
  await ref.read(channelRosterControllerProvider.notifier).clear();
  await ref.read(channelControllerProvider.notifier).clear();
  await ref.read(favoritesControllerProvider.notifier).clear();
  await ref.read(pinnedChatsControllerProvider.notifier).clear();
  await ref.read(hiddenChatsControllerProvider.notifier).clear();
  // Who you went looking for is its own trace, and it lives in its own list.
  await ref.read(recentSearchesControllerProvider.notifier).clear();
  // Which cuts of the chat list you keep above it says something about who you
  // talk to, and a fresh install has no folders at all.
  await ref.read(chatFoldersControllerProvider.notifier).clear();
  await ref.read(userChatFoldersControllerProvider.notifier).clear();
  await ref.read(mapFriendsControllerProvider.notifier).clear();
  // Where those friends were last seen is on disk now, so it has to be wiped
  // like everything else — a map that still has pins on it after a wipe is a
  // list of people and places the wipe was supposed to remove.
  ref.read(mapPresenceStoreProvider.notifier).clear();
  await ref.read(pinnedControllerProvider.notifier).clear();
  await ref.read(draftsControllerProvider.notifier).clearAll();
  await ref.read(fileTransferControllerProvider.notifier).clearAll();
  ref.read(presenceControllerProvider.notifier).clear();
  ref.read(typingControllerProvider.notifier).clearAll();
  // A wiped install has to be indistinguishable from a fresh one, and a fresh
  // one has not seen the intro.
  await ref.read(onboardingControllerProvider.notifier).reset();
  await ref.read(nicknameControllerProvider.notifier).reset();
  // Switches the internet fallback off and forgets any custom relay list, so
  // the next launch talks to nobody until the user opts in again.
  await ref.read(relaySettingsProvider.notifier).reset();
  // Discoverability goes back to the default too — a wipe should leave the app
  // indistinguishable from a fresh install, including how it advertises itself.
  await ref.read(avatarProvider.notifier).reset();
  // Back to the stock look: a wipe should leave the app looking like a fresh
  // install, and a chosen palette is a visible trace of the person who chose it.
  await ref.read(themeControllerProvider.notifier).reset();
  // Which emoji you reach for is a habit, and a habit is a trace.
  await ref.read(reactionEmojiControllerProvider.notifier).reset();
  // Same for how big you like the interface: a fresh install follows the phone.
  await ref.read(uiScaleControllerProvider.notifier).reset();
  await ref.read(discoverySettingsProvider.notifier).reset();
  await ref.read(privacySettingsProvider.notifier).reset();

  final sessions = ref.read(chatSessionManagerProvider);
  final manager = ref.read(chatSessionManagerProvider.notifier);
  for (final peerId in sessions.keys.toList()) {
    manager.drop(peerId);
  }

  // Drop any encrypted frames we were holding for other peers (relay buffer).
  ref.read(messagingServiceProvider).clearRelayBuffer();

  // 2. Forward-secret prekeys keep live private state in their provider.
  await ref.read(prekeyServiceProvider).wipe();

  // 3. On-disk persistence.
  await HiveInit.wipeAll();

  // 4. The crypto identity + the Hive data-encryption key in the secure
  //    store. Erasing the AES key renders any encrypted box bytes that
  //    survived step 2 (e.g. a file the OS hadn't flushed) unrecoverable.
  await ref.read(identityServiceProvider).wipe();
  await hiveCipherProvider.wipe();
  ref.invalidate(identityProvider);
  ref.invalidate(prekeyServiceProvider);
  ref.invalidate(messagingServiceProvider);

  // Everything that holds a Hive box has to be built again.
  //
  // Each of these was emptied through its own API above, which is correct and
  // not enough: the box handle it cached is now a handle to a file that has
  // been deleted. The controller does not know that, so the next thing it
  // saves throws "Box has already been closed" and is simply lost — which on a
  // phone transfer means the imported pins, avatar and nickname are written
  // into nothing and the new phone comes up anonymous.
  //
  // The rule, for whoever adds the next one: if a controller keeps a `Box` in
  // a field, its provider belongs in this list.
  for (final provider in [
    messagesControllerProvider,
    knownPeersControllerProvider,
    peerAvatarsControllerProvider,
    contactAliasesControllerProvider,
    channelAvatarsControllerProvider,
    channelDescriptionsControllerProvider,
    channelRosterControllerProvider,
    channelControllerProvider,
    favoritesControllerProvider,
    pinnedChatsControllerProvider,
    hiddenChatsControllerProvider,
    recentSearchesControllerProvider,
    chatFoldersControllerProvider,
    userChatFoldersControllerProvider,
    mapFriendsControllerProvider,
    mapPresenceStoreProvider,
    pinnedControllerProvider,
    draftsControllerProvider,
    readMarkersControllerProvider,
    conversationSettingsControllerProvider,
  ]) {
    ref.invalidate(provider);
  }
}
