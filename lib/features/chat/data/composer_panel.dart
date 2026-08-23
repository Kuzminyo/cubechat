import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the composer's emoji/sticker panel is open in this chat.
///
/// The flag itself belongs to the composer — this is the copy the rest of the
/// route can read, kept in step by `ChatInput.onPanelOpenChanged`.
///
/// It exists because back is answered by whoever is deepest in a mode, and
/// Flutter tells *every* [PopScope] on a route about a blocked pop rather than
/// only the one that blocked it. On a chat opened from search, where the
/// redirect's own `canPop` is already false, that press was read as "nothing
/// underneath, go to the chats list" — so back with the panel open closed the
/// panel and left the chat in one gesture. The redirect asks this the same way
/// it asks [messageSelectionProvider] about a running selection.
///
/// Family-scoped and auto-disposing like the rest of the per-chat scratch
/// state: leaving the conversation takes the panel with it. Auto-disposing has
/// a consequence for the reader — the redirect has to `watch` this, not `read`
/// it when the press arrives, because with no listener the state written by the
/// composer would be thrown away before anybody asked for it.
final composerPanelOpenProvider =
    NotifierProvider.autoDispose.family<ComposerPanelOpen, bool, String>(
  ComposerPanelOpen.new,
);

class ComposerPanelOpen extends AutoDisposeFamilyNotifier<bool, String> {
  @override
  bool build(String arg) => false;

  void setOpen(bool open) {
    if (state != open) state = open;
  }
}
