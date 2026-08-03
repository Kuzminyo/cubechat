import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/models/message.dart';
import '../../peers/presentation/widgets/peer_avatar.dart';
import '../data/recent_searches_controller.dart';
import '../models/chat.dart';
import 'chats_list_screen.dart';
import 'widgets/chat_tile.dart';

/// People to offer before anything has been typed.
///
/// Favourites first, because that list is the user saying outright who matters;
/// nothing inferred should outrank it. The rest fills up by how much has
/// actually been said, which is a steadier signal than recency — "who I talk to
/// most" barely moves, while "who I messaged last" is already the top of the
/// chat list one screen back, and repeating it here would waste the row.
///
/// Channels are left out: this row is a strip of faces, and a channel has none.
@visibleForTesting
List<Chat> frequentChats(
  List<Chat> chats,
  Map<String, List<Message>> messagesByChat, {
  int limit = 10,
}) {
  int volume(Chat c) => (messagesByChat[c.id] ?? const []).length;
  final people = chats.where((c) => !c.isChannel && volume(c) > 0).toList()
    ..sort((a, b) {
      if (a.isFavorite != b.isFavorite) return a.isFavorite ? -1 : 1;
      final byVolume = volume(b).compareTo(volume(a));
      if (byVolume != 0) return byVolume;
      // Stable tail so the row does not reshuffle between builds.
      return a.peerName.toLowerCase().compareTo(b.peerName.toLowerCase());
    });
  return people.take(limit).toList();
}

@visibleForTesting
String routeForChatFromSearch(Chat chat) {
  final route = Uri.parse(routeForChat(chat));
  return route.replace(
      queryParameters: {...route.queryParameters, 'from': 'search'}).toString();
}

/// Full-screen chat search.
///
/// A screen rather than a field that filters the list in place: with nothing
/// typed there is something useful to show — who you talk to, and who you last
/// looked up — and that has nowhere to live on a list already full of chats.
class ChatSearchScreen extends ConsumerStatefulWidget {
  const ChatSearchScreen({super.key});

  @override
  ConsumerState<ChatSearchScreen> createState() => _ChatSearchScreenState();
}

class _ChatSearchScreenState extends ConsumerState<ChatSearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    // Opened by tapping a search field, so the keyboard should already be up —
    // making the user tap a second time to start typing would be the whole
    // reason this screen exists, undone.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _open(Chat chat) {
    // Remembered on the way out, not on the way in: the list is "who I went
    // looking for and found", and typing a name you never open says nothing.
    ref.read(recentSearchesControllerProvider.notifier).remember(chat.id);
    context.push(routeForChatFromSearch(chat));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final chats = ref.watch(chatsProvider);
    final query = _query.trim().toLowerCase();

    final results = query.isEmpty
        ? const <Chat>[]
        : chats.where((c) => c.peerName.toLowerCase().contains(query)).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: BackButton(color: AppColors.textOnGlass),
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 16),
          child: FloatingGlass(
            blur: false,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            borderRadius: 14,
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              onChanged: (v) => setState(() => _query = v),
              cursorColor: AppColors.brandPrimary,
              textInputAction: TextInputAction.search,
              style: TextStyle(color: AppColors.textOnGlass, fontSize: 14),
              decoration: InputDecoration(
                icon: Icon(Icons.search,
                    size: 18, color: AppColors.textOnGlassFaint),
                border: InputBorder.none,
                isCollapsed: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                hintText: t.chatsSearchHint,
                hintStyle: TextStyle(
                  color: AppColors.textOnGlassFaint,
                  fontSize: 14,
                ),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: Icon(Icons.close,
                            size: 18, color: AppColors.textOnGlassDim),
                        onPressed: () {
                          _controller.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
        ),
      ),
      body: query.isEmpty
          ? _Suggestions(onOpen: _open)
          : _Results(
              results: results, onOpen: _open, emptyLabel: t.chatsSearchEmpty),
    );
  }
}

/// What the screen shows before anything is typed.
class _Suggestions extends ConsumerWidget {
  const _Suggestions({required this.onOpen});

  final void Function(Chat) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final chats = ref.watch(chatsProvider);
    final frequent =
        frequentChats(chats, ref.watch(messagesControllerProvider));
    final recentIds = ref.watch(recentSearchesControllerProvider);

    // An id can outlive the chat it named — the contact was deleted, the
    // channel left. Resolving through the live list drops those silently.
    final byId = {for (final c in chats) c.id: c};
    final recent = [
      for (final id in recentIds)
        if (byId[id] != null) byId[id]!,
    ];

    if (frequent.isEmpty && recent.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            t.chatsSearchStartHint,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        if (frequent.isNotEmpty) ...[
          _SectionLabel(text: t.chatsSearchFrequent),
          SizedBox(
            height: 104,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: frequent.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, i) => _FrequentTile(
                chat: frequent[i],
                onTap: () => onOpen(frequent[i]),
              ),
            ),
          ),
        ],
        if (recent.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    t.chatsSearchRecent,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => ref
                      .read(recentSearchesControllerProvider.notifier)
                      .clear(),
                  child: Text(
                    t.chatsSearchClear,
                    style: TextStyle(
                      color: AppColors.brandPrimary,
                      fontSize: 12.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final chat in recent)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: FloatingGlass(
                blur: false,
                borderRadius: 18,
                onTap: () => onOpen(chat),
                child: ChatTile(chat: chat),
              ),
            ),
        ],
      ],
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({
    required this.results,
    required this.onOpen,
    required this.emptyLabel,
  });

  final List<Chat> results;
  final void Function(Chat) onOpen;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return Center(
        child: Text(
          emptyLabel,
          style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      itemCount: results.length,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: FloatingGlass(
          blur: false,
          borderRadius: 18,
          onTap: () => onOpen(results[i]),
          child: ChatTile(chat: results[i]),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
        child: Text(
          text,
          style: TextStyle(
            color: AppColors.textOnGlassDim,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
      );
}

/// One face in the frequent row: avatar over a clipped name.
class _FrequentTile extends StatelessWidget {
  const _FrequentTile({required this.chat, required this.onTap});

  final Chat chat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 68,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PeerAvatar(
              peerId: chat.peerId,
              label: chat.peerName,
              size: 60,
              online: chat.isOnline,
            ),
            const SizedBox(height: 6),
            Text(
              chat.peerName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textOnGlass,
                fontSize: 11.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
