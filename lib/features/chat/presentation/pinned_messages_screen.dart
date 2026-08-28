import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/routing/page_transitions.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/aurora_background.dart';
import '../../../core/theme/typography.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/transport/messaging_service.dart';
import '../data/pinned_controller.dart';
import '../models/message.dart';

/// Every pinned message in one conversation, as a screen of its own.
///
/// The bar at the top of a chat shows one pin at a time and steps through them
/// on tap, which is right for two or three and useless for twenty — there is no
/// way to see what is pinned, and no way to reach the fourth one except by
/// tapping past the first three. This is the list that answers both.
///
/// Pushed with [screenRoute] rather than a sheet, so it gets the same slide and
/// the same edge-drag back as every other screen. A sheet would have needed its
/// own dismissal and would not have answered the back gesture.
Future<void> openPinnedMessages(
  BuildContext context, {
  required String chatId,
  required List<Message> pinned,
  required void Function(Message message) onJump,
}) {
  return Navigator.of(context).push<void>(
    screenRoute<void>(
      (_) => _PinnedMessagesScreen(
        chatId: chatId,
        pinned: pinned,
        onJump: onJump,
      ),
    ),
  );
}

class _PinnedMessagesScreen extends ConsumerStatefulWidget {
  const _PinnedMessagesScreen({
    required this.chatId,
    required this.pinned,
    required this.onJump,
  });

  final String chatId;

  /// Oldest first, the same order the bar steps through them in.
  final List<Message> pinned;

  /// Take the conversation to this message. The screen closes first, because
  /// the thing being jumped to is behind it.
  final void Function(Message message) onJump;

  @override
  ConsumerState<_PinnedMessagesScreen> createState() =>
      _PinnedMessagesScreenState();
}

class _PinnedMessagesScreenState extends ConsumerState<_PinnedMessagesScreen> {
  /// Wire ids ticked here.
  ///
  /// Deliberately local rather than the conversation's own selection provider.
  /// That one drives the chat's action bar, and sharing it would mean leaving
  /// this screen dropped you back into a chat in selection mode over messages
  /// you cannot see — which is the bug the archive screen already had to have
  /// fixed for the same reason.
  final Set<String> _picked = <String>{};

  bool get _selecting => _picked.isNotEmpty;

  void _toggle(String wireId) => setState(() {
        if (!_picked.remove(wireId)) _picked.add(wireId);
      });

  /// Unpin, and tell the other side.
  ///
  /// Through `sendPin(pinned: false)` rather than the controller's own `unpin`,
  /// which is what the bar in the conversation does. A pin is a shared fact —
  /// both phones show the same bar — so unpinning locally would have left the
  /// other person looking at something this one had already dropped, and the
  /// next sync would have brought it back.
  Future<void> _unpick(Iterable<String> ids) async {
    final t = AppLocalizations.of(context);
    // Asked once, however many are ticked.
    //
    // Unpinning is not destructive — the message stays — but it is invisible
    // and awkward to undo: you have to find the message again in the history to
    // pin it back. The conversation's own bar already asks before unpinning for
    // that reason, and this is the same act with more of them selected.
    if (!await confirmAction(
      context,
      title: t.chatUnpinConfirm,
      message: t.chatUnpinConfirmHint,
      confirmLabel: t.chatUnpinAction,
      destructive: false,
    )) {
      return;
    }
    if (!mounted) return;
    final messaging = ref.read(messagingServiceProvider);
    for (final id in ids) {
      await messaging.sendPin(widget.chatId, id, pinned: false);
    }
    if (!mounted) return;
    setState(_picked.clear);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    // Watched for the rebuild, read through the notifier for the answer: the
    // controller keys its map its own way and `pinnedAllIn` is what knows how.
    ref.watch(pinnedControllerProvider);
    final pinnedIds = {
      for (final pin in ref.read(pinnedControllerProvider.notifier).pinnedAllIn(
            widget.chatId,
          ))
        pin.wireId,
    };
    final rows = [
      for (final m in widget.pinned)
        if (m.wireId != null && pinnedIds.contains(m.wireId)) m,
    ];

    return PopScope<void>(
      // Picking is a mode, and back closes a mode before it closes a screen —
      // the same order the conversation itself uses.
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !_selecting) return;
        setState(_picked.clear);
      },
      // The screen paints its own backdrop.
      //
      // Without one the Scaffold is transparent and the conversation underneath
      // shows straight through it — so during the slide you see the chat's
      // messages, and only when the route settles does anything look like a
      // separate screen. It read as the window arriving late, and it is what
      // every other pushed screen here already avoids by carrying the aurora.
      child: AuroraBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: BackButton(
              color: AppColors.textOnGlass,
              onPressed: () => _selecting
                  ? setState(_picked.clear)
                  : Navigator.of(context).maybePop(),
            ),
            title: Text(
              _selecting
                  ? t.chatSelectedCount(_picked.length)
                  : t.chatPinnedCount(rows.length),
              style: AppTypography.heading(size: 17),
            ),
            actions: [
              if (_selecting)
                IconButton(
                  tooltip: t.chatUnpinAction,
                  icon: Icon(Icons.push_pin_rounded,
                      color: AppColors.textOnGlass),
                  onPressed: () => _unpick(_picked.toList()),
                ),
            ],
          ),
          body: rows.isEmpty
              ? Center(
                  child: Text(
                    t.chatNoPins,
                    style: TextStyle(color: AppColors.textOnGlassDim),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final m = rows[i];
                    final id = m.wireId!;
                    return _PinnedRow(
                      message: m,
                      selected: _picked.contains(id),
                      onTap: () {
                        if (_selecting) {
                          _toggle(id);
                          return;
                        }
                        // Close first: the message being jumped to is in the
                        // conversation behind this screen.
                        Navigator.of(context).pop();
                        widget.onJump(m);
                      },
                      onLongPress: () => _toggle(id),
                    );
                  },
                ),
          bottomNavigationBar: rows.isEmpty
              ? null
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: TextButton(
                      onPressed: () =>
                          _unpick([for (final m in rows) m.wireId!]),
                      child: Text(
                        t.chatUnpinAll,
                        style: TextStyle(color: AppColors.danger),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// One pinned message.
///
/// Selected rows are tinted with the same colour and the same 260 ms ease the
/// conversation uses, so a pin picked here and a message picked there look like
/// the same act rather than two different ones.
class _PinnedRow extends StatelessWidget {
  const _PinnedRow({
    required this.message,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final Message message;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.brandPrimary.withValues(alpha: 0.22)
            : AppColors.pane(0.35),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              children: [
                // The green rule down the left is the same mark a quoted
                // message carries in the conversation.
                Container(
                  width: 3,
                  height: 34,
                  decoration: BoxDecoration(
                    color: AppColors.brandPrimary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _preview(message),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 13.5,
                      height: 1.25,
                    ),
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: 10),
                  Icon(
                    Icons.check_circle_rounded,
                    size: 20,
                    color: AppColors.brandPrimary,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Same rules as the pinned bar's one-liner: a media message says what it is
  /// when it has no caption worth showing.
  static String _preview(Message m) {
    final text = m.text.trim();
    switch (m.kind) {
      case MessageKind.image:
        return text.isEmpty || text.startsWith('image/') ? '📷 Photo' : text;
      case MessageKind.audio:
        return '🎤 Voice message';
      case MessageKind.file:
        return '📎 ${m.fileName ?? 'File'}';
      case MessageKind.poll:
        return '📊 $text';
      case MessageKind.text:
        return text;
    }
  }
}
