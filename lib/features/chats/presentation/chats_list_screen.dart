import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/identity/wipe_service.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/chat_session_manager.dart';
import '../../../core/widgets/appear_animation.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../core/widgets/triple_tap_detector.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/data/messages_controller.dart';
import '../../peers/data/known_peers_controller.dart';
import '../models/chat.dart';
import 'widgets/chat_tile.dart';

enum ChatsFilter { all, unread, mesh, favorites }

final chatsFilterProvider = StateProvider<ChatsFilter>((_) => ChatsFilter.all);
final chatsQueryProvider = StateProvider<String>((_) => '');

/// Real chat list — one entry per **authenticated peer ever seen**, keyed by
/// the peer's static pubkey (stable across BLE Privacy address rotation).
/// The entry sticks around in the list after the peer disconnects, so the
/// user can revisit the conversation and see history.
///
/// "Online" is derived from whether any live ChatSessionManager session has
/// the same pubkey — i.e. a transport handshake is currently up.
final chatsProvider = Provider<List<Chat>>((ref) {
  final known = ref.watch(knownPeersControllerProvider);
  final messagesByChat = ref.watch(messagesControllerProvider);
  final sessions = ref.watch(chatSessionManagerProvider);

  final onlinePubkeys = <String>{
    for (final s in sessions.values)
      if (s.isEstablished && s.remotePubkeyHex != null) s.remotePubkeyHex!,
  };

  final entries = known.values.map((peer) {
    final msgs = messagesByChat[peer.pubkeyHex] ?? const [];
    final last = msgs.isNotEmpty ? msgs.last : null;
    final unread = msgs.where((m) => !m.isMine).length;
    return Chat(
      id: peer.pubkeyHex,
      peerId: peer.pubkeyHex,
      peerName: peer.displayName,
      lastMessage: last?.text ?? 'Secured · Noise XX',
      lastTime: last?.sentAt ?? peer.lastSeen,
      unreadCount: unread,
      isMesh: true,
      isOnline: onlinePubkeys.contains(peer.pubkeyHex),
    );
  }).toList();
  entries.sort((a, b) => b.lastTime.compareTo(a.lastTime));
  return entries;
});

class ChatsListScreen extends ConsumerWidget {
  const ChatsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final filter = ref.watch(chatsFilterProvider);
    final query = ref.watch(chatsQueryProvider).toLowerCase();
    final all = ref.watch(chatsProvider);

    final filtered = all.where((c) {
      switch (filter) {
        case ChatsFilter.all:
          break;
        case ChatsFilter.unread:
          if (c.unreadCount == 0) return false;
        case ChatsFilter.mesh:
          if (!c.isMesh) return false;
        case ChatsFilter.favorites:
          if (!c.isFavorite) return false;
      }
      if (query.isEmpty) return true;
      return c.peerName.toLowerCase().contains(query) ||
          c.lastMessage.toLowerCase().contains(query);
    }).toList();

    return SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      TripleTapDetector(
                        onTripleTap: () => _confirmWipe(context, ref, t),
                        child: const CubeLogo(size: 32),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(t.chatsTitle, style: AppTypography.display()),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t.chatsSubtitle,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textOnGlassDim,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _SearchField(
                onChanged: (v) => ref.read(chatsQueryProvider.notifier).state = v,
                hint: t.chatsSearchHint,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 56,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                children: [
                  _FilterPill(label: t.chatsFilterAll, value: ChatsFilter.all, current: filter, ref: ref),
                  const SizedBox(width: 8),
                  _FilterPill(label: t.chatsFilterUnread, value: ChatsFilter.unread, current: filter, ref: ref),
                  const SizedBox(width: 8),
                  _FilterPill(label: t.chatsFilterMesh, value: ChatsFilter.mesh, current: filter, ref: ref),
                  const SizedBox(width: 8),
                  _FilterPill(label: t.chatsFilterFavorites, value: ChatsFilter.favorites, current: filter, ref: ref),
                ],
              ),
            ),
          ),
          if (filtered.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyState(title: t.chatsEmptyTitle, hint: t.chatsEmptyHint),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 140),
              sliver: SliverList.separated(
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final chat = filtered[i];
                  return AppearAnimation(
                    delay: Duration(milliseconds: 40 * i),
                    child: GlassCard(
                      padding: EdgeInsets.zero,
                      borderRadius: 18,
                      child: ChatTile(
                        chat: chat,
                        onTap: () => context.push(
                          '/chat/${Uri.encodeComponent(chat.peerId)}'
                          '?name=${Uri.encodeQueryComponent(chat.peerName)}',
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.onChanged, required this.hint});

  final ValueChanged<String> onChanged;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      borderRadius: 14,
      child: TextField(
        onChanged: onChanged,
        cursorColor: AppColors.brandPrimary,
        style: TextStyle(color: AppColors.textOnGlass, fontSize: 14),
        decoration: InputDecoration(
          icon: Icon(Icons.search, size: 18, color: AppColors.textOnGlassFaint),
          border: InputBorder.none,
          isCollapsed: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
          hintText: hint,
          hintStyle: TextStyle(color: AppColors.textOnGlassFaint, fontSize: 14),
        ),
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.value,
    required this.current,
    required this.ref,
  });

  final String label;
  final ChatsFilter value;
  final ChatsFilter current;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    return PillButton(
      label: label,
      active: value == current,
      onTap: () => ref.read(chatsFilterProvider.notifier).state = value,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.glassFill,
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: Icon(Icons.chat_bubble_outline, color: AppColors.textOnGlassDim, size: 28),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                color: AppColors.textOnGlass,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

/// Triple-tap on the cube logo lands here — the bitchat-style emergency
/// wipe gesture. We still ask for confirmation; the gesture is the secret
/// shortcut, not a way to skip the confirmation.
Future<void> _confirmWipe(
  BuildContext context,
  WidgetRef ref,
  AppLocalizations t,
) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.bgTop,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
      ),
      title: Text(
        t.profileEmergencyWipeConfirm,
        style: TextStyle(
          color: AppColors.textOnGlass,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Text(
        t.profileEmergencyWipeConfirmHint,
        style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(t.cancel, style: TextStyle(color: AppColors.textOnGlassDim)),
        ),
        TextButton(
          onPressed: () async {
            await emergencyWipe(ref);
            if (!ctx.mounted) return;
            Navigator.of(ctx).pop();
          },
          child: Text(
            t.profileEmergencyWipeAction,
            style: const TextStyle(color: AppColors.danger),
          ),
        ),
      ],
    ),
  );
}
