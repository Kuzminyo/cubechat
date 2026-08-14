import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/domain/message_preview.dart';
import '../../../core/identity/nickname_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../chats/models/chat.dart';
import '../../chats/presentation/chats_list_screen.dart';
import '../../profile/data/privacy_settings_controller.dart';
import '../data/map_friend_link.dart';
import '../data/map_friends_controller.dart';
import '../../peers/presentation/widgets/peer_avatar.dart';

Future<void> showMapInviteSheet(BuildContext context) => showGlassSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (_) => const _MapInviteSheet(),
    );

class _MapInviteSheet extends ConsumerStatefulWidget {
  const _MapInviteSheet();

  @override
  ConsumerState<_MapInviteSheet> createState() => _MapInviteSheetState();
}

class _MapInviteSheetState extends ConsumerState<_MapInviteSheet> {
  final _selected = <String>{};
  bool _sending = false;

  Future<void> _copyLink(String link) async {
    final t = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    showGlassToast(
      context,
      t.chatCopied,
      icon: Icons.copy_rounded,
      tone: ToastTone.success,
    );
  }

  Future<void> _send(List<Chat> chats, String link) async {
    if (_selected.isEmpty || _sending) return;
    setState(() => _sending = true);

    final t = AppLocalizations.of(context);
    final navigator = Navigator.of(context);
    final messaging = ref.read(messagingServiceProvider);
    var sent = 0;

    final friends = ref.read(mapFriendsControllerProvider.notifier);
    // Inviting people to your map is the consent the map-sharing switch asks
    // for, so it is granted here rather than hidden in Privacy for the user to
    // go and find. Without it the invitation "worked" and nothing happened:
    // both sides paired, neither ever appeared, because a beacon is only sent
    // while sharing is on and it defaults to off.
    await ref.read(privacySettingsProvider.notifier).setShareMapLocation(true);
    for (final chat in chats) {
      if (!_selected.contains(chat.id)) continue;
      try {
        await messaging.sendText(chat.peerId, link);
        // Inviting somebody to your map *is* the act of sharing it with them,
        // so it takes effect here rather than when their acceptance gets back.
        // Waiting for the reply is what used to leave the two phones
        // disagreeing — they had you, you did not have them, and the only way
        // out anybody found was an invitation back down the other direction.
        await friends.activate(chat.peerId);
        sent++;
      } catch (_) {
        // One unavailable contact must not prevent the remaining invitations.
      }
    }

    if (!mounted) return;
    showGlassToast(
      context,
      sent == 0 ? t.mapInviteFailed : t.mapInviteSent(sent),
      icon: sent == 0 ? Icons.error_outline_rounded : Icons.send_rounded,
      tone: sent == 0 ? ToastTone.danger : ToastTone.success,
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final nickname = ref.watch(nicknameControllerProvider);
    final inviteLink = MapFriendLink.invite(displayName: nickname).encode();
    final chats = ref
        .watch(chatsProvider)
        .where((chat) => !chat.isChannel)
        .toList(growable: false);
    final height = MediaQuery.sizeOf(context).height * 0.78;

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
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
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
                      Icons.person_add_alt_1_rounded,
                      color: AppColors.brandPrimary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.mapInviteTitle,
                          style: TextStyle(
                            color: AppColors.textOnGlass,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          t.mapInviteHint,
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                decoration: BoxDecoration(
                  color: AppColors.glassFill,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AppColors.glass(0.14)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        inviteLink,
                        maxLines: 3,
                        style: TextStyle(
                          color: AppColors.textOnGlass,
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: () => _copyLink(inviteLink),
                      tooltip: t.chatCopyAction,
                      icon: Icon(
                        Icons.copy_rounded,
                        color: AppColors.brandPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            if (chats.isEmpty)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                      t.mapInviteEmpty,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textOnGlassDim),
                    ),
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: chats.length,
                  itemBuilder: (_, index) {
                    final chat = chats[index];
                    final selected = _selected.contains(chat.id);
                    return CheckboxListTile(
                      value: selected,
                      activeColor: AppColors.brandPrimary,
                      checkColor: Colors.black,
                      controlAffinity: ListTileControlAffinity.trailing,
                      onChanged: _sending
                          ? null
                          : (value) => setState(() {
                                if (value ?? false) {
                                  _selected.add(chat.id);
                                } else {
                                  _selected.remove(chat.id);
                                }
                              }),
                      secondary: PeerAvatar(
                        peerId: chat.peerId,
                        label: chat.peerName,
                        size: 42,
                        online: chat.isOnline,
                      ),
                      title: Text(
                        chat.peerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppColors.textOnGlass),
                      ),
                      subtitle: Text(
                        storedTextPreview(chat.lastMessage, t),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textOnGlassDim,
                          fontSize: 11.5,
                        ),
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
                  onPressed: _selected.isEmpty || _sending
                      ? null
                      : () => _send(chats, inviteLink),
                  icon: _sending
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : const Icon(Icons.send_rounded),
                  label: Text(t.mapInviteAction(_selected.length)),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.brandPrimary,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: AppColors.glass(0.08),
                    disabledForegroundColor: AppColors.textOnGlassFaint,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
