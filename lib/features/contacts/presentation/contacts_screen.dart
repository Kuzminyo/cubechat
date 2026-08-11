import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/appear_animation.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../peers/presentation/widgets/peer_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/data/messages_controller.dart';
import '../../chats/data/hidden_chats_controller.dart';
import '../../chats/models/chat.dart';
import '../../chats/presentation/chats_list_screen.dart';

/// Who belongs in Contacts: people you have actually corresponded with, and
/// people you did until you deleted the conversation.
///
/// History alone used to be the whole rule, which quietly made "delete chat"
/// mean "delete contact": clearing the messages emptied the only evidence this
/// screen accepted, and somebody you had talked to for months was gone from
/// Contacts — keys, npub and all still on disk, but no way left to reach them
/// short of swapping codes again. [deletedChatIds] is the other half of the
/// evidence. A conversation you deleted is a conversation you had.
///
/// Note what this still excludes: a phone that merely walked past yours is in
/// the peer roster and in neither of these sets, so Contacts stays a list of
/// people rather than a list of strangers the radio has met.
List<Chat> contactChatsFromHistory(
  Iterable<Chat> chats,
  Iterable<String> chatIdsWithHistory, {
  Iterable<String> deletedChatIds = const <String>[],
}) {
  final ids = chatIdsWithHistory.toSet();
  final deleted = deletedChatIds.toSet();
  final contacts = chats
      .where((chat) =>
          !chat.isChannel &&
          (ids.contains(chat.id) || deleted.contains(chat.id)))
      .toList();
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
  // Deliberately the unfiltered list: chatsProvider has already dropped the
  // deleted conversations, which are exactly the contacts this screen was
  // losing.
  final chats = ref.watch(allChatsProvider);
  final messagesByChat = ref.watch(messagesControllerProvider);
  return contactChatsFromHistory(
    chats,
    messagesByChat.entries
        .where((entry) => entry.value.isNotEmpty)
        .map((entry) => entry.key),
    deletedChatIds: ref.watch(hiddenChatsControllerProvider),
  );
});
String routeForContactProfile(Chat contact) =>
    '/person/${Uri.encodeComponent(contact.peerId)}'
    '?name=${Uri.encodeQueryComponent(contact.peerName)}';

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
        // Scrolling the list puts the search keyboard away. This screen is the
        // one tab-root that owns a text field, so it is also the one that could
        // strand a keyboard on top of the whole shell; dragging past the field
        // is the gesture that says you are done with it.
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
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
                      // A channel is the one thing here that is not a person,
                      // so it gets the megaphone rather than a place in the
                      // list. Same dialog the Chats menu opens.
                      IconButton(
                        onPressed: () => showNewChannelDialog(context, ref, t),
                        icon: const Icon(Icons.campaign_outlined),
                        color: AppColors.brandPrimary,
                        iconSize: 26,
                        tooltip: t.chatsMenuNewChannel,
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
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          // Above the list rather than behind a menu: this screen is the
          // answer to "who do I know", so the way to add someone belongs in
          // plain sight — and it stays put while the list below it filters.
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: FloatingGlass(
                blur: false,
                borderRadius: 18,
                onTap: () => context.push('/contact'),
                child: _AddContactRow(label: t.chatsMenuAddContact),
              ),
            ),
          ),
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
              sliver: AppearOnce(
                builder: (context, animate) => SliverList.separated(
                  itemCount: contacts.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final contact = contacts[index];
                    return AppearAnimation(
                      enabled: animate,
                      delay: AppearAnimation.stagger(index),
                      child: FloatingGlass(
                        blur: false,
                        borderRadius: 18,
                        onTap: () =>
                            context.push(routeForContactProfile(contact)),
                        child: _ContactTile(contact: contact),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The pinned row that opens the contact-card screen.
///
/// Shaped like a contact tile — same height, same avatar-sized leading circle —
/// so it reads as the first entry in the list rather than a banner bolted on
/// above it.
class _AddContactRow extends StatelessWidget {
  const _AddContactRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.brandPrimary.withValues(alpha: 0.16),
              border: Border.all(
                color: AppColors.brandPrimary.withValues(alpha: 0.38),
              ),
            ),
            child: Icon(
              Icons.person_add_alt,
              color: AppColors.brandPrimary,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textOnGlass,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
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
      blur: false,
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
          PeerAvatar(
            peerId: contact.peerId,
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
                      Icon(
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
