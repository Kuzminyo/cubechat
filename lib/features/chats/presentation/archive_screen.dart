import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/appear_animation.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../data/archived_chats_controller.dart';
import '../data/swipe_action_controller.dart';
import 'chats_list_screen.dart' show archivedChatsProvider, routeForChat;
import 'widgets/chat_tile.dart';
import 'widgets/swipe_action_row.dart';

/// The drawer: conversations put out of the way, still working.
///
/// A screen rather than a section that expands at the top of the list. An
/// expanding section has to decide what happens to the folder pills, the
/// search, the reorder mode and the selection bar while it is open, and the
/// answer to all four is "nothing good". A push has none of those questions and
/// gives the rows the whole screen.
///
/// The swipe is the same gesture as on the main list and does the same thing,
/// which here means putting a chat back — the action is its own undo, so
/// nobody has to learn a second one.
class ArchiveScreen extends ConsumerWidget {
  const ArchiveScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final chats = ref.watch(archivedChatsProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: BackButton(color: AppColors.textOnGlass),
        title: Text(
          t.chatsArchiveTitle,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
      ),
      body: SafeArea(
        top: false,
        child: chats.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.archive_outlined,
                        size: 40,
                        color: AppColors.textOnGlassFaint,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        t.chatsArchiveEmpty,
                        style: TextStyle(
                          color: AppColors.textOnGlassDim,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : AppearOnce(
                builder: (context, animate) => ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 140),
                  itemCount: chats.length + 1,
                  itemBuilder: (context, i) {
                    if (i == chats.length) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(6, 14, 6, 0),
                        child: Text(
                          t.chatsArchiveHint,
                          style: TextStyle(
                            color: AppColors.textOnGlassFaint,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      );
                    }
                    final chat = chats[i];
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: i == chats.length - 1 ? 0 : 8,
                      ),
                      child: AppearAnimation(
                        enabled: animate,
                        delay: AppearAnimation.stagger(i),
                        child: SwipeActionRow(
                          // Always the archive action here, whatever the user
                          // chose for the main list: on this screen there is
                          // one thing anybody wants to do to a row, and it is
                          // to take it out again.
                          action: ChatSwipeAction.archive,
                          onFire: () async {
                            await ref
                                .read(archivedChatsControllerProvider.notifier)
                                .unarchive(chat.id);
                            if (context.mounted) {
                              showGlassToast(
                                context,
                                t.chatsUnarchivedToast,
                                icon: Icons.unarchive_rounded,
                              );
                            }
                            return true;
                          },
                          child: FloatingGlass(
                            blur: false,
                            borderRadius: 18,
                            onTap: () => context.push(routeForChat(chat)),
                            child: ChatTile(chat: chat),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
