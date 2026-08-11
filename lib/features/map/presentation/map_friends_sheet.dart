import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../chats/models/chat.dart';
import '../../chats/presentation/chats_list_screen.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../peers/models/known_peer.dart';
import '../../peers/presentation/widgets/peer_avatar.dart';
import '../data/map_focus_request.dart';
import '../data/map_friends_controller.dart';
import '../data/shared_map_locations_provider.dart';
import 'map_invite_sheet.dart';

/// Who is actually on the map with you — and the way back out.
///
/// This used to open the invite list, which showed every contact regardless of
/// whether they had anything to do with the map. That answers "who could I
/// invite", but the question a map raises is "who can see me", and the two
/// lists are nothing alike: one is the address book, the other is the handful
/// of people this screen is actually about. Inviting is still here, one tap
/// away, because it is a different question rather than a hidden one.
Future<void> showMapFriendsSheet(BuildContext context) =>
    showGlassSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (_) => const _MapFriendsSheet(),
    );

class _MapFriendsSheet extends ConsumerWidget {
  const _MapFriendsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final friends = ref.watch(mapFriendsControllerProvider);
    final peers = ref.watch(knownPeersControllerProvider);
    final live = ref.watch(sharedMapLocationsProvider);
    final chats = {
      for (final chat in ref.watch(chatsProvider)) chat.peerId: chat,
    };

    final entries = friends.toList(growable: false)
      ..sort((a, b) {
        final aLive = live[a] != null;
        final bLive = live[b] != null;
        if (aLive != bLive) return aLive ? -1 : 1;
        return _nameFor(a, peers, chats).toLowerCase().compareTo(
              _nameFor(b, peers, chats).toLowerCase(),
            );
      });

    final height = MediaQuery.sizeOf(context).height * 0.7;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: height),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.glass(0.24),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.brandPrimary.withValues(alpha: 0.14),
                    ),
                    child: Icon(
                      Icons.groups_rounded,
                      color: AppColors.brandPrimary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.mapFriendsTitle,
                          style: TextStyle(
                            color: AppColors.textOnGlass,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          t.mapFriendsHint,
                          style: TextStyle(
                            color: AppColors.textOnGlassDim,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (entries.isEmpty)
              Flexible(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 18, 28, 18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.person_pin_circle_outlined,
                          color: AppColors.textOnGlassFaint,
                          size: 42,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          t.mapFriendsEmpty,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textOnGlass,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          t.mapFriendsEmptyHint,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textOnGlassDim,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: entries.length,
                  itemBuilder: (_, index) {
                    final chatId = entries[index];
                    final name = _nameFor(chatId, peers, chats);
                    final onMap = live[chatId] != null;
                    return ListTile(
                      // Tapping a row answers "where are they", which is the
                      // question the list raises and the map can already
                      // answer: close the sheet and put them under the camera.
                      // Somebody with no position has nowhere to be taken to,
                      // so say that rather than dismissing the sheet onto an
                      // unchanged map and leaving the tap looking broken.
                      onTap: () {
                        if (!onMap) {
                          showGlassToast(
                            context,
                            t.mapFriendsIdle,
                            icon: Icons.location_off_rounded,
                          );
                          return;
                        }
                        Navigator.of(context).pop();
                        ref.read(mapFocusRequestProvider.notifier).state =
                            MapFocusRequest(chatId);
                      },
                      leading: PeerAvatar(
                        peerId: chatId,
                        label: name,
                        size: 42,
                        online: onMap,
                      ),
                      title: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppColors.textOnGlass),
                      ),
                      subtitle: Text(
                        onMap ? t.mapFriendsLive : t.mapFriendsIdle,
                        style: TextStyle(
                          color: onMap
                              ? AppColors.brandPrimary
                              : AppColors.textOnGlassDim,
                          fontSize: 11.5,
                        ),
                      ),
                      trailing: IconButton(
                        tooltip: t.mapFriendsRemove,
                        icon: Icon(
                          Icons.person_remove_alt_1_rounded,
                          color: AppColors.danger,
                        ),
                        onPressed: () async {
                          final messenger = AppLocalizations.of(context);
                          await ref
                              .read(mapFriendsControllerProvider.notifier)
                              .forget(chatId);
                          // Their pin goes with them: dropping someone has to
                          // clear the position already on screen, or the person
                          // you just removed keeps standing there until their
                          // last beacon times out.
                          ref
                              .read(mapPresenceStoreProvider.notifier)
                              .forget(chatId);
                          if (!context.mounted) return;
                          showGlassToast(
                            context,
                            messenger.mapFriendsRemoved(name),
                            icon: Icons.person_remove_alt_1_rounded,
                            tone: ToastTone.success,
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    showMapInviteSheet(context);
                  },
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  label: Text(t.mapFriendsInvite),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.brandPrimary,
                    foregroundColor: Colors.black,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A map friend is stored as a chat id, which is a pubkey — never something
  /// to show a person. Known peers hold the name they announced; the chat list
  /// is the fallback for a contact we have talked to but not heard announce.
  static String _nameFor(
    String chatId,
    Map<String, KnownPeer> peers,
    Map<String, Chat> chats,
  ) {
    final announced = peers[chatId]?.displayName;
    if (announced != null && announced.trim().isNotEmpty) return announced;
    final chatName = chats[chatId]?.peerName;
    if (chatName != null && chatName.trim().isNotEmpty) return chatName;
    return chatId.length > 12 ? '${chatId.substring(0, 12)}…' : chatId;
  }
}
