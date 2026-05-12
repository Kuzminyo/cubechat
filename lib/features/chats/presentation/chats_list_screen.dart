import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/appear_animation.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../l10n/app_localizations.dart';
import '../data/mock_chats.dart';
import '../models/chat.dart';
import 'widgets/chat_tile.dart';

enum ChatsFilter { all, unread, mesh, favorites }

final chatsFilterProvider = StateProvider<ChatsFilter>((_) => ChatsFilter.all);
final chatsQueryProvider = StateProvider<String>((_) => '');
final chatsProvider = Provider<List<Chat>>((_) => mockChats());

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
                      const CubeLogo(size: 32),
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
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
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
                        onTap: () => context.push('/chat/${chat.id}', extra: chat),
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
