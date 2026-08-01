import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/appear_animation.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/data/messages_controller.dart';
import '../../chats/models/chat.dart';
import '../../chats/presentation/chats_list_screen.dart';

List<Chat> contactChatsFromHistory(
  Iterable<Chat> chats,
  Iterable<String> chatIdsWithHistory,
) {
  final ids = chatIdsWithHistory.toSet();
  final contacts =
      chats.where((chat) => !chat.isChannel && ids.contains(chat.id)).toList();
  contacts.sort((a, b) {
    final byName = a.peerName.toLowerCase().compareTo(
          b.peerName.toLowerCase(),
        );
    if (byName != 0) return byName;
    return b.lastTime.compareTo(a.lastTime);
  });
  return contacts;
}

final contactChatsProvider = Provider<List<Chat>>((ref) {
  final chats = ref.watch(chatsProvider);
  final messagesByChat = ref.watch(messagesControllerProvider);
  return contactChatsFromHistory(
    chats,
    messagesByChat.entries
        .where((entry) => entry.value.isNotEmpty)
        .map((entry) => entry.key),
  );
});

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final all = ref.watch(contactChatsProvider);
    final query = _query.trim().toLowerCase();
    final contacts = query.isEmpty
        ? all
        : all
            .where((contact) => contact.peerName.toLowerCase().contains(query))
            .toList();

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
                    children: [
                      const Icon(
                        Icons.contacts_rounded,
                        color: AppColors.brandPrimary,
                        size: 30,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          t.contactsTitle,
                          style: AppTypography.display(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    t.contactsSubtitle,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _ContactsSearchField(
                hint: t.contactsSearchHint,
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
          if (contacts.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _ContactsEmptyState(
                title:
                    all.isEmpty ? t.contactsEmptyTitle : t.contactsSearchEmpty,
                hint: all.isEmpty ? t.contactsEmptyHint : t.contactsSearchHint,
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 140),
              sliver: SliverList.separated(
                itemCount: contacts.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final contact = contacts[index];
                  return AppearAnimation(
                    delay: AppearAnimation.stagger(index),
                    child: FloatingGlass(
                      borderRadius: 18,
                      onTap: () => context.push(routeForChat(contact)),
                      child: _ContactTile(contact: contact),
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

class _ContactsSearchField extends StatelessWidget {
  const _ContactsSearchField({
    required this.hint,
    required this.onChanged,
  });

  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return FloatingGlass(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      borderRadius: 14,
      child: TextField(
        onChanged: onChanged,
        textCapitalization: TextCapitalization.words,
        cursorColor: AppColors.brandPrimary,
        style: TextStyle(
          color: AppColors.textOnGlass,
          fontSize: 14,
        ),
        decoration: InputDecoration(
          icon: Icon(
            Icons.search,
            size: 18,
            color: AppColors.textOnGlassFaint,
          ),
          border: InputBorder.none,
          isCollapsed: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
          hintText: hint,
          hintStyle: TextStyle(
            color: AppColors.textOnGlassFaint,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({required this.contact});

  final Chat contact;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final status = contact.isOnline
        ? t.presenceOnline
        : contact.isReachableViaMesh
            ? t.chatsStatusViaMesh
            : t.chatsStatusOffline;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          IdentityAvatar(
            seed: contact.peerId,
            label: contact.peerName,
            size: 48,
            online: contact.isOnline,
            heroTag: 'contact-avatar-${contact.peerId}',
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        contact.peerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textOnGlass,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (contact.isVerified) ...[
                      const SizedBox(width: 5),
                      const Icon(
                        Icons.verified,
                        color: AppColors.brandPrimary,
                        size: 15,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  status,
                  style: TextStyle(
                    color: contact.isOnline
                        ? AppColors.brandPrimary
                        : AppColors.textOnGlassDim,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: AppColors.textOnGlassFaint,
          ),
        ],
      ),
    );
  }
}

class _ContactsEmptyState extends StatelessWidget {
  const _ContactsEmptyState({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 72, 32, 140),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.contacts_outlined,
            color: AppColors.textOnGlassFaint,
            size: 46,
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
