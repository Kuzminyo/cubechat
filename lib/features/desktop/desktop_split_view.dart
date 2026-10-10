import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/colors.dart';
import '../../core/util/platform_capabilities.dart';
import '../../core/widgets/aurora_background.dart';
import '../chat/presentation/chat_screen.dart';
import '../chats/models/chat.dart';
import '../chats/presentation/chats_list_screen.dart';

/// The conversation open in the right-hand column of a wide computer window.
@immutable
class DesktopOpenChat {
  const DesktopOpenChat({required this.peerId, required this.label});

  /// What [ChatScreen.peerId] takes: a pubkey, `#channel`, or Saved's id.
  final String peerId;
  final String label;
}

final desktopOpenChatProvider =
    StateProvider<DesktopOpenChat?>((_) => null);

/// Whether a chat opens in the right-hand column here rather than as a page.
bool desktopSplits(BuildContext context, WidgetRef ref) =>
    !ref.read(platformCapabilitiesProvider).bluetooth &&
    MediaQuery.sizeOf(context).width >= DesktopSplitView.minWidth;

/// Open [chat]: beside the list on a wide computer window, as a page anywhere
/// else.
void openChat(BuildContext context, WidgetRef ref, Chat chat) {
  if (desktopSplits(context, ref)) {
    ref.read(desktopOpenChatProvider.notifier).state = DesktopOpenChat(
      peerId: chat.peerId,
      label: chat.peerName,
    );
    return;
  }
  context.push(routeForChat(chat));
}

/// Telegram Desktop's shape: the whole phone interface in a column on the
/// left — tabs, bar and all — and the open conversation filling the rest.
///
/// Only on a computer and only past [minWidth]; narrower, and on every phone,
/// it is [list] and nothing else. Each column is handed a `MediaQuery` of its
/// own width, because screens here lay themselves out from the window's width
/// and would otherwise spread a 400 px list over the whole window.
class DesktopSplitView extends ConsumerWidget {
  const DesktopSplitView({super.key, required this.list, this.detailBuilder});

  final Widget list;

  /// The right-hand column for [DesktopOpenChat]; `close` empties it. The
  /// conversation itself unless a test says otherwise.
  final Widget Function(DesktopOpenChat open, VoidCallback close)?
      detailBuilder;

  static const double minWidth = 900;
  static const double listWidth = 400;

  /// Key of the right-hand column while nothing is open.
  static const String emptyHint = 'cubechat-desktop-empty';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = MediaQuery.of(context);
    final split = !ref.watch(platformCapabilitiesProvider).bluetooth &&
        media.size.width >= minWidth;
    if (!split) return list;
    final open = ref.watch(desktopOpenChatProvider);
    void close() => ref.read(desktopOpenChatProvider.notifier).state = null;
    final detailWidth = media.size.width - listWidth - 1;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: listWidth,
          child: MediaQuery(
            data: media.copyWith(size: Size(listWidth, media.size.height)),
            child: list,
          ),
        ),
        ColoredBox(color: AppColors.glass(0.10), child: const SizedBox(width: 1)),
        Expanded(
          child: MediaQuery(
            data: media.copyWith(size: Size(detailWidth, media.size.height)),
            child: open == null
                ? const _EmptyPane()
                : KeyedSubtree(
                    // A different chat is a different screen, not the same
                    // one told new facts halfway through its state.
                    key: ValueKey(open.peerId),
                    child: (detailBuilder ?? _chat)(open, close),
                  ),
          ),
        ),
      ],
    );
  }

  static Widget _chat(DesktopOpenChat open, VoidCallback close) =>
      AuroraBackground(
        child: ChatScreen(
          peerId: open.peerId,
          peerLabel: open.label,
          onClose: close,
        ),
      );
}

class _EmptyPane extends StatelessWidget {
  const _EmptyPane();

  @override
  Widget build(BuildContext context) => AuroraBackground(
        child: Center(
          child: Icon(
            Icons.forum_outlined,
            key: const ValueKey(DesktopSplitView.emptyHint),
            size: 56,
            color: AppColors.textOnGlassFaint,
          ),
        ),
      );
}
