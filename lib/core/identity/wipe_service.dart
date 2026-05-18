import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat/data/messages_controller.dart';
import '../../features/peers/data/known_peers_controller.dart';
import '../crypto/identity_service.dart';
import '../storage/hive_init.dart';
import '../transport/chat_session_manager.dart';
import 'nickname_controller.dart';

/// Emergency wipe.
///
/// Drops every byte of cubechat state on this device:
/// - In-memory: messages, known peers, nickname, every live Noise session
/// - On disk:   all Hive boxes (messages, known peers, settings)
/// - Secure:    the X25519 identity private key in Keychain / Keystore
///
/// After this call, opening the app again is indistinguishable from a fresh
/// install — a brand new identity gets minted on first read of
/// identityProvider, and chats list is empty.
Future<void> emergencyWipe(WidgetRef ref) async {
  // 1. In-memory state first so nothing tries to re-persist mid-wipe.
  await ref.read(messagesControllerProvider.notifier).clearAll();
  await ref.read(knownPeersControllerProvider.notifier).clear();
  await ref.read(nicknameControllerProvider.notifier).reset();

  final sessions = ref.read(chatSessionManagerProvider);
  final manager = ref.read(chatSessionManagerProvider.notifier);
  for (final peerId in sessions.keys.toList()) {
    manager.drop(peerId);
  }

  // 2. On-disk persistence.
  await HiveInit.wipeAll();

  // 3. The crypto identity in the secure store.
  await ref.read(identityServiceProvider).wipe();
  ref.invalidate(identityProvider);
}
