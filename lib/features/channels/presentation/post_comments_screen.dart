import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/routing/page_transitions.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/aurora_background.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/models/message.dart';
import '../../chat/presentation/widgets/chat_input.dart';
import '../../peers/presentation/widgets/peer_avatar.dart';
import 'channel_viewer_bar.dart';

/// The comments on one post, and nothing else.
///
/// The first version of this opened the whole discussion room, which is a flat
/// conversation: a reader looking for what was said about *this* announcement
/// found every remark about every announcement, in the order they happened.
/// Comments are per post or they are not comments.
///
/// The thread is kept by the reply target, which channel messages have carried
/// for as long as rooms have shown quotes — a comment is an ordinary message in
/// the discussion room whose reply points at the post. So there is no thread
/// object anywhere, nothing to create, nothing to keep in step, and a build
/// that has never heard of comments sees a group chat full of quoted replies,
/// which is exactly what it is.
Future<void> openPostComments(
  BuildContext context, {
  required String channelName,
  required Message post,
}) {
  return Navigator.of(context).push<void>(
    screenRoute<void>(
      (_) => _PostCommentsScreen(channelName: channelName, post: post),
    ),
  );
}

class _PostCommentsScreen extends ConsumerStatefulWidget {
  const _PostCommentsScreen({required this.channelName, required this.post});

  final String channelName;
  final Message post;

  @override
  ConsumerState<_PostCommentsScreen> createState() =>
      _PostCommentsScreenState();
}

class _PostCommentsScreenState extends ConsumerState<_PostCommentsScreen> {
  /// The discussion room this post's comments live in, once it is open.
  ///
  /// Derived from the channel's key rather than asked for, so opening comments
  /// is arithmetic — see [openCommunityFor]. Null while that is in flight, and
  /// null for good if we are not in the channel at all.
  String? _community;
  bool _joining = true;

  @override
  void initState() {
    super.initState();
    _join();
  }

  Future<void> _join() async {
    final name = await openCommunityFor(ref, widget.channelName);
    if (!mounted) return;
    setState(() {
      _community = name;
      _joining = false;
    });
  }

  Future<void> _send(String text) async {
    final room = _community;
    final target = widget.post.wireId;
    if (room == null || target == null || text.trim().isEmpty) return;
    try {
      await ref.read(messagingServiceProvider).sendChannelText(
            room,
            text.trim(),
            replyToWireId: target,
            // Kept with the comment so the thread survives without having to
            // find the post again — the same reason a reply carries one in a
            // private chat.
            replyPreview: _preview(widget.post),
          );
    } catch (e) {
      if (!mounted) return;
      showGlassToast(context, '$e', tone: ToastTone.danger);
    }
  }

  static String _preview(Message m) {
    final text = m.text.trim();
    return switch (m.kind) {
      MessageKind.image =>
        text.isEmpty || text.startsWith('image/') ? '📷' : text,
      MessageKind.audio => '🎤',
      MessageKind.file => '📎',
      MessageKind.poll => '📊 $text',
      MessageKind.text => text,
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final room = _community;
    final target = widget.post.wireId;
    final comments = room == null || target == null
        ? const <Message>[]
        : [
            for (final m in ref.watch(
              messagesControllerProvider.select(
                (all) => all[room] ?? const <Message>[],
              ),
            ))
              if (m.replyToWireId == target) m,
          ];

    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: AppColors.textOnGlass,
          title: Text(
            t.channelPostComments,
            style: AppTypography.heading(size: 17),
          ),
        ),
        body: Column(
          children: [
            _PostCard(post: widget.post),
            Expanded(
              child: _joining
                  ? const Center(child: CircularProgressIndicator())
                  : room == null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Text(
                              t.channelCommunityOpen,
                              textAlign: TextAlign.center,
                              style:
                                  TextStyle(color: AppColors.textOnGlassDim),
                            ),
                          ),
                        )
                      : comments.isEmpty
                          ? Center(
                              child: Text(
                                t.channelNoComments,
                                style: TextStyle(
                                  color: AppColors.textOnGlassDim,
                                ),
                              ),
                            )
                          : ListView.builder(
                              padding:
                                  const EdgeInsets.fromLTRB(12, 4, 12, 12),
                              itemCount: comments.length,
                              itemBuilder: (context, i) =>
                                  _CommentRow(comment: comments[i]),
                            ),
            ),
            if (room != null)
              SafeArea(
                top: false,
                child: ChatInput(
                  hint: t.channelCommentHint,
                  sendTooltip: t.chatSend,
                  onSend: _send,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The post itself, pinned above its comments so the thread has a subject.
class _PostCard extends StatelessWidget {
  const _PostCard({required this.post});

  final Message post;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.pane(0.35),
        borderRadius: BorderRadius.circular(16),
        border: Border(
          left: BorderSide(color: AppColors.brandPrimary, width: 3),
        ),
      ),
      child: Text(
        _PostCommentsScreenState._preview(post),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: AppColors.textOnGlass,
          fontSize: 13.5,
          height: 1.3,
        ),
      ),
    );
  }
}

/// One remark, with the face of whoever made it.
class _CommentRow extends StatelessWidget {
  const _CommentRow({required this.comment});

  final Message comment;

  @override
  Widget build(BuildContext context) {
    final name = comment.authorName ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (comment.authorId case final id?) ...[
            PeerAvatar(peerId: id, label: name, size: 26),
            const SizedBox(width: 9),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (name.isNotEmpty)
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.authorTint(comment.authorId ?? name),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                Text(
                  comment.text,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 14,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
