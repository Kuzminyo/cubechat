import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/theme/typography.dart';
import '../../../../core/widgets/glass_sheet.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../peers/presentation/widgets/peer_avatar.dart';
import '../../../chat/domain/message_preview.dart';
import '../../models/chat.dart';
import '../chats_list_screen.dart';

/// Choose one or several chats to send something into.
///
/// Replaces the little dialog that forwarding used to open. A dialog asks
/// "which one" and can only be answered once; sending the same thing to three
/// people meant opening it three times, and the list inside it was four rows
/// tall on a phone that had room for twelve. This is the list itself: the
/// conversations, with their faces and their last line, ticked as you go.
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
  final chosen = await showGlassSheet<List<Chat>>(
    context: context,
    builder: (_) => _ChatPickerSheet(
      title: title,
      exceptChatId: exceptChatId,
      includeChannels: includeChannels,
    ),
  );
  return chosen ?? const <Chat>[];
}

class _ChatPickerSheet extends ConsumerStatefulWidget {
  const _ChatPickerSheet({
    required this.title,
    required this.exceptChatId,
    required this.includeChannels,
  });

  final String title;
  final String? exceptChatId;
  final bool includeChannels;

  @override
  ConsumerState<_ChatPickerSheet> createState() => _ChatPickerSheetState();
}

class _ChatPickerSheetState extends ConsumerState<_ChatPickerSheet> {
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

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        // Tall on purpose. The point of this over a dialog is that the list is
        // long enough to scroll rather than four rows in a box.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.78,
        ),
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
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: AppTypography.heading(size: AppMenu.title),
                    ),
                  ),
                  if (_picked.isNotEmpty)
                    Text(
                      '${_picked.length}',
                      style: TextStyle(
                        color: AppColors.brandPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _search,
                onChanged: (v) => setState(() => _query = v),
                style: TextStyle(color: AppColors.textOnGlass, fontSize: 14.5),
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
              Flexible(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: chats.length,
                  itemBuilder: (_, i) {
                    final chat = chats[i];
                    final picked = _picked.contains(chat.id);
                    return CheckboxListTile(
                      value: picked,
                      activeColor: AppColors.brandPrimary,
                      checkColor: Colors.black,
                      controlAffinity: ListTileControlAffinity.trailing,
                      onChanged: (on) => setState(() {
                        if (on ?? false) {
                          _picked.add(chat.id);
                        } else {
                          _picked.remove(chat.id);
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
                          fontSize: AppMenu.rowSubtitle,
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
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.brandPrimary,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  // Disabled until something is ticked, rather than sending to
                  // nobody and closing: a button that does nothing is worse
                  // than one that says it cannot yet.
                  onPressed: _picked.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(
                            chats.where((c) => _picked.contains(c.id)).toList(),
                          ),
                  icon: const Icon(Icons.send_rounded, size: 18),
                  label: Text(t.chatForwardSendCount(_picked.length)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
