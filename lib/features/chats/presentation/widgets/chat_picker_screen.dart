import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/routing/page_transitions.dart';
import '../../../../core/theme/colors.dart';
import '../../../../core/theme/typography.dart';
import '../../../../core/widgets/aurora_background.dart';
import '../../../../core/widgets/floating_glass.dart';
import '../../../../l10n/app_localizations.dart';
import '../../models/chat.dart';
import '../chats_list_screen.dart';
import 'chat_tile.dart';

/// Choose one or several chats to send something into.
///
/// A full screen, not a dialog and not a sheet: forwarding in Telegram opens
/// the chat list itself and you pick there, and that is the shape people expect
/// because sending onward is the same act as opening a chat. The old dialog
/// could be answered once and stood four rows tall on a phone with room for
/// twelve; a half-height sheet was the same list in a smaller box. This is the
/// list at full height — faces, last line, a search, ticked as you go.
///
/// Returns the chats that were ticked, or an empty list if it was dismissed.
Future<List<Chat>> showChatPicker(
  BuildContext context, {
  required String title,

  /// The chat you are standing in, which is never a destination.
  String? exceptChatId,

  /// Rooms as well as people. Off for anything addressed to one person.
  bool includeChannels = true,
}) async {
  final chosen = await Navigator.of(context, rootNavigator: true).push<List<Chat>>(
    screenRoute<List<Chat>>(
      (_) => _ChatPickerScreen(
        title: title,
        exceptChatId: exceptChatId,
        includeChannels: includeChannels,
      ),
    ),
  );
  return chosen ?? const <Chat>[];
}

class _ChatPickerScreen extends ConsumerStatefulWidget {
  const _ChatPickerScreen({
    required this.title,
    required this.exceptChatId,
    required this.includeChannels,
  });

  final String title;
  final String? exceptChatId;
  final bool includeChannels;

  @override
  ConsumerState<_ChatPickerScreen> createState() => _ChatPickerScreenState();
}

class _ChatPickerScreenState extends ConsumerState<_ChatPickerScreen> {
  final Set<String> _picked = <String>{};
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final query = _query.trim().toLowerCase();
    final chats = ref
        .watch(chatsProvider)
        .where((c) => c.id != widget.exceptChatId)
        .where((c) => widget.includeChannels || !c.isChannel)
        .where((c) => query.isEmpty || c.peerName.toLowerCase().contains(query))
        .toList(growable: false);

    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: BackButton(color: AppColors.textOnGlass),
          title: Text(
            widget.title,
            style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
          ),
          actions: [
            if (_picked.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Center(
                  child: Text(
                    '${_picked.length}',
                    style: TextStyle(
                      color: AppColors.brandPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  controller: _search,
                  onChanged: (v) => setState(() => _query = v),
                  style:
                      TextStyle(color: AppColors.textOnGlass, fontSize: 14.5),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.glassFill,
                    hintText: t.chatsSearchHint,
                    hintStyle: TextStyle(
                      color: AppColors.textOnGlassFaint,
                      fontSize: 14,
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      color: AppColors.textOnGlassDim,
                      size: AppMenu.rowIcon,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: AppColors.glass(0.14)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: AppColors.glass(0.14)),
                    ),
                  ),
                ),
              ),
              if (chats.isEmpty)
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        t.chatForwardEmpty,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textOnGlassDim),
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                    itemCount: chats.length,
                    itemBuilder: (_, i) {
                      final chat = chats[i];
                      final picked = _picked.contains(chat.id);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: FloatingGlass(
                          blur: false,
                          borderRadius: 18,
                          onTap: () => setState(() {
                            if (!_picked.remove(chat.id)) _picked.add(chat.id);
                          }),
                          child: Row(
                            children: [
                              // The tile keeps its own trailing column — the
                              // time, the pin, the ticks — so the checkbox
                              // gets a column of its own rather than a place
                              // on top of them. Overlaid, it sat squarely on
                              // the timestamp.
                              Expanded(child: ChatTile(chat: chat)),
                              Padding(
                                padding: const EdgeInsets.only(right: 14),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 140),
                                  width: 22,
                                  height: 22,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: picked
                                        ? AppColors.brandPrimary
                                        : Colors.transparent,
                                    border: Border.all(
                                      color: picked
                                          ? AppColors.brandPrimary
                                          : AppColors.glass(0.35),
                                      width: 1.6,
                                    ),
                                  ),
                                  child: picked
                                      ? const Icon(
                                          Icons.check_rounded,
                                          size: 15,
                                          color: Colors.black,
                                        )
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        // The send button floats over the list rather than pinning a bar to
        // the bottom, so a long list scrolls behind it and nothing is hidden.
        floatingActionButton: _picked.isEmpty
            ? null
            : FloatingActionButton.extended(
                backgroundColor: AppColors.brandPrimary,
                foregroundColor: Colors.black,
                onPressed: () => Navigator.of(context).pop(
                  chats.where((c) => _picked.contains(c.id)).toList(),
                ),
                icon: const Icon(Icons.send_rounded),
                label: Text(t.chatForwardSendCount(_picked.length)),
              ),
      ),
    );
  }
}
