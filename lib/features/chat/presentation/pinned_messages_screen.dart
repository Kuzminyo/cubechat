import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/routing/page_transitions.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../core/widgets/aurora_background.dart';
import '../../../core/theme/typography.dart';
import '../../../core/utils/time_format.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/transport/messaging_service.dart';
import 'widgets/chat_input.dart';
import '../data/messages_controller.dart';
import '../data/pinned_controller.dart';
import 'widgets/message_bubble.dart';
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

  /// The picked pins, in the order the list shows them.
  List<Message> _pickedFrom(List<Message> rows) => [
        for (final m in rows)
          if (_picked.contains(m.wireId)) m
      ];

  /// Everything ticked, as text, one message per line.
  Future<void> _copy(List<Message> rows) async {
    final t = AppLocalizations.of(context);
    final text = [
      for (final m in _pickedFrom(rows))
        if (copyableText(m) case final line?) line,
    ].join('\n');
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(_picked.clear);
    showGlassToast(context, t.chatCopied, icon: Icons.copy_rounded);
  }

  /// Pass them on, through the same picker the conversation uses.
  Future<void> _forward(List<Message> rows) async {
    final picked = _pickedFrom(rows);
    if (picked.isEmpty) return;
    final targets = await pickForwardTargets(context, ref, widget.chatId);
    if (targets.isEmpty || !mounted) return;
    for (final target in targets) {
      for (final message in picked) {
        await forwardMessageTo(
          ref,
          target,
          message,
          fromChatId: widget.chatId,
        );
      }
    }
    if (!mounted) return;
    setState(_picked.clear);
    showGlassToast(
      context,
      targets.length == 1
          ? AppLocalizations.of(context).chatForwardSent(targets.first.peerName)
          : AppLocalizations.of(context).chatForwardSentCount(targets.length),
      icon: Icons.shortcut_rounded,
    );
  }

  /// Off this phone, and off the pinned bar with it.
  ///
  /// Local only, like the conversation's own "delete for me": a pin is a shared
  /// fact and the message is somebody's words, so removing both for everybody
  /// from a list screen is more than anybody tapping here has asked for. The
  /// pin goes too, because a pin pointing at a message this device no longer
  /// holds is a bar that cannot be opened.
  Future<void> _delete(List<Message> rows) async {
    final t = AppLocalizations.of(context);
    final picked = _pickedFrom(rows);
    if (picked.isEmpty) return;
    if (!await confirmAction(
      context,
      title: t.chatDeleteAction,
      message: t.chatDeleteForMeHint,
      confirmLabel: t.chatDeleteAction,
      destructive: true,
    )) {
      return;
    }
    if (!mounted) return;
    final messages = ref.read(messagesControllerProvider.notifier);
    final messaging = ref.read(messagingServiceProvider);
    for (final message in picked) {
      final wireId = message.wireId;
      if (wireId != null) {
        await messaging.sendPin(widget.chatId, wireId, pinned: false);
      }
      messages.deleteLocal(widget.chatId, message.id);
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
          // No AppBar. This screen is reached from a conversation and looks
          // like one — a floating capsule over the aurora rather than a bar
          // owning a band of the screen, which is the shape every other
          // surface here already has.
          appBar: null,
          body: Column(
            children: [
              _PinnedHeader(
                title: _selecting
                    ? t.chatSelectedCount(_picked.length)
                    : t.chatPinnedCount(rows.length),
                onBack: () => _selecting
                    ? setState(_picked.clear)
                    : Navigator.of(context).maybePop(),
                // A pin is a message, and everything you can do to a message
                // you can do to it here. The screen listed them and offered
                // exactly one verb — so reading something worth keeping meant
                // going back to the conversation to find it before it could be
                // copied or passed on, which is the search this list exists to
                // save.
                actions: !_selecting
                    ? const []
                    : [
                        _PinnedHeaderAction(
                          tooltip: t.chatCopyAction,
                          icon: Icons.copy_rounded,
                          onPressed: () => _copy(rows),
                        ),
                        _PinnedHeaderAction(
                          tooltip: t.chatForwardAction,
                          icon: Icons.shortcut_rounded,
                          onPressed: () => _forward(rows),
                        ),
                        _PinnedHeaderAction(
                          tooltip: t.chatDeleteAction,
                          icon: Icons.delete_outline_rounded,
                          color: AppColors.danger,
                          onPressed: () => _delete(rows),
                        ),
                        _PinnedHeaderAction(
                          tooltip: t.chatUnpinAction,
                          iconWidget: _UnpinIcon(color: AppColors.textOnGlass),
                          onPressed: () => _unpick(_picked.toList()),
                        ),
                      ],
              ),
              Expanded(
                child: rows.isEmpty
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
                          // Grouped by the day they were written, like the
                          // conversation they came out of. A list of twenty pins
                          // gathered over a month reads as one block without it.
                          final newDay = startsNewDay(
                            m.sentAt,
                            i == 0 ? null : rows[i - 1].sentAt,
                          );
                          final row = _PinnedRow(
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
                          if (!newDay) return row;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [_PinnedDayLine(day: m.sentAt), row],
                          );
                        },
                      ),
              ),
              // The composer's place, and the composer's island: this is the
              // one thing the screen does to everything at once, and a bare
              // line of red text at the bottom of the glass was the only
              // control here that did not look like part of the app.
              if (rows.isNotEmpty)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    child: MessageIslandGlass(
                      borderRadius: 26,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(26),
                          onTap: () =>
                              _unpick([for (final m in rows) m.wireId!]),
                          child: SizedBox(
                            height: 52,
                            child: Center(
                              child: Text(
                                t.chatUnpinAll,
                                style: TextStyle(
                                  color: AppColors.danger,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The screen's own header capsule.
///
/// The same island the conversation floats at its top — same glass, same
/// height, same round button on the leading edge — because this screen is
/// reached from a conversation and belongs to it. An `AppBar` here was the one
/// surface in the app still shaped like a bar.
class _PinnedHeader extends StatelessWidget {
  const _PinnedHeader({
    required this.title,
    required this.onBack,
    required this.actions,
  });

  final String title;
  final VoidCallback onBack;
  final List<Widget> actions;

  /// The conversation header's height, so the two read as the same object at
  /// two moments rather than two headers.
  static const double _height = 56;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Owns the status-bar inset, exactly as the chat header does: there is no
      // AppBar left to hold the capsule clear of the notch.
      padding:
          EdgeInsets.fromLTRB(8, MediaQuery.paddingOf(context).top + 4, 8, 4),
      child: SizedBox(
        height: _height,
        child: MessageIslandGlass(
          borderRadius: _height / 2,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            children: [
              _PinnedHeaderAction(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: Icons.arrow_back_rounded,
                onPressed: onBack,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.heading(size: 16),
                ),
              ),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }
}

/// One round control on the header capsule.
class _PinnedHeaderAction extends StatelessWidget {
  const _PinnedHeaderAction({
    required this.tooltip,
    required this.onPressed,
    this.icon,
    this.iconWidget,
    this.color,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData? icon;

  /// For the crossed-out pin, which is drawn rather than a glyph.
  final Widget? iconWidget;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: Ink(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppColors.glass(0.18), AppColors.glass(0.10)],
              ),
            ),
            child: Center(
              child: iconWidget ??
                  Icon(icon, size: 20, color: color ?? AppColors.textOnGlass),
            ),
          ),
        ),
      ),
    );
  }
}

/// The date a run of pins was written on. See the comments screen, which draws
/// the same thing for the same reason.
class _PinnedDayLine extends StatelessWidget {
  const _PinnedDayLine({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 4),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.pane(0.55),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.glass(0.12)),
          ),
          child: Text(
            formatDayHeader(context, day),
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// A pin with a line through it.
///
/// Material has `link_off`, `notifications_off` and a dozen more, and no
/// crossed-out pin — so it is drawn the way those are: the glyph, and a stroke
/// across it at the angle Material uses for the rest of the family.
///
/// Two strokes, not one. The wider one is the backdrop's own dark and sits
/// behind the bright one, which is what keeps the line readable where it
/// crosses the thickest part of the pin instead of vanishing into it.
class _UnpinIcon extends StatelessWidget {
  const _UnpinIcon({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final size = IconTheme.of(context).size ?? 24;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.push_pin_rounded, color: color, size: size),
          Transform.rotate(
            angle: -0.785398,
            child: Container(
              width: size * 0.92,
              height: 3.4,
              decoration: BoxDecoration(
                color: AppColors.paneBase,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Transform.rotate(
            angle: -0.785398,
            child: Container(
              width: size * 0.92,
              height: 1.8,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ],
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
