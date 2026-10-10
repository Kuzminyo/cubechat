import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/colors.dart';
import '../../core/util/platform_capabilities.dart';
import '../../core/widgets/aurora_background.dart';
import '../../l10n/app_localizations.dart';
import '../chat/presentation/chat_screen.dart';
import '../chats/models/chat.dart';
import '../chats/presentation/chats_list_screen.dart';
import '../peers/presentation/widgets/peer_avatar.dart';
import 'desktop_rail.dart';

/// The conversation open in the right-hand pane of a computer window.
@immutable
class DesktopOpenChat {
  const DesktopOpenChat({required this.peerId, required this.label});

  /// What [ChatScreen.peerId] takes: a pubkey, `#channel`, or Saved's id.
  final String peerId;
  final String label;
}

final desktopOpenChatProvider =
    StateProvider<DesktopOpenChat?>((_) => null);

/// How a window lays itself out. A phone is always [phone].
enum DesktopMode {
  /// One column, the phone's layout and bottom bar.
  phone,

  /// The rail, a column of avatars, and the open chat.
  compact,

  /// The rail, the chat list, and the open chat — Telegram Desktop's shape.
  wide,
}

DesktopMode desktopModeFor(double width, PlatformCapabilities caps) {
  if (caps.bluetooth) return DesktopMode.phone;
  if (width >= DesktopSplitView.wideFrom) return DesktopMode.wide;
  if (width >= DesktopSplitView.compactFrom) return DesktopMode.compact;
  return DesktopMode.phone;
}

/// Which [DesktopMode] the window is in, for the screens inside it: the shell
/// leaves out its bottom bar and the chat list its folder row while the rail
/// carries both.
class DesktopChrome extends InheritedWidget {
  const DesktopChrome({super.key, required this.mode, required super.child});

  final DesktopMode mode;

  static DesktopMode of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopChrome>()?.mode ??
      DesktopMode.phone;

  /// The rail is on screen: no bottom bar, no folder row.
  static bool railShown(BuildContext context) =>
      of(context) != DesktopMode.phone;

  @override
  bool updateShouldNotify(DesktopChrome old) => old.mode != mode;
}

/// Whether a chat opens in the right-hand pane here rather than as a page.
bool desktopSplits(BuildContext context, WidgetRef ref) =>
    desktopModeFor(
      MediaQuery.sizeOf(context).width,
      ref.read(platformCapabilitiesProvider),
    ) !=
    DesktopMode.phone;

/// Open [chat]: in the right-hand pane on a computer window, as a page
/// anywhere else.
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

/// A computer window, as Telegram Desktop lays one out.
///
/// Wide: the rail, the chat list, and the open chat filling the rest. Narrower,
/// the list shrinks to a column of faces. Narrower still — and on every phone —
/// it is [list] alone, the phone's own layout. Each column is handed a
/// `MediaQuery` of its own width: screens here lay themselves out from the
/// window's width and would otherwise spread a 360 px list over all of it.
class DesktopSplitView extends ConsumerWidget {
  const DesktopSplitView({
    super.key,
    required this.list,
    this.currentBranch = 0,
    this.onBranch,
    this.detailBuilder,
  });

  /// The phone's interface: the shell with its tabs.
  final Widget list;

  /// The shell branch on show, and how the rail switches it.
  final int currentBranch;
  final ValueChanged<int>? onBranch;

  /// The right-hand pane for [DesktopOpenChat]; `close` empties it. The
  /// conversation itself unless a test says otherwise.
  final Widget Function(DesktopOpenChat open, VoidCallback close)?
      detailBuilder;

  static const double wideFrom = 900;
  static const double compactFrom = 640;
  static const double listWidth = 360;
  static const double compactWidth = 76;

  /// Key of the right-hand pane while nothing is open.
  static const String emptyHint = 'cubechat-desktop-empty';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = MediaQuery.of(context);
    final mode =
        desktopModeFor(media.size.width, ref.watch(platformCapabilitiesProvider));
    if (mode == DesktopMode.phone) return list;

    final open = ref.watch(desktopOpenChatProvider);
    void close() => ref.read(desktopOpenChatProvider.notifier).state = null;
    // Faces instead of the chat list when the window is too narrow for names,
    // or when the person folded the list down to them. Only on Chats: any
    // other section keeps its full column.
    final faces = currentBranch == 0 &&
        (mode == DesktopMode.compact ||
            ref.watch(desktopListCollapsedProvider));
    final middle = faces ? compactWidth : listWidth;
    final detailWidth =
        media.size.width - DesktopRail.width - middle - 1;

    return DesktopChrome(
      mode: mode,
      // The shell sits under its own Scaffold; the rail, the faces and the
      // empty pane do not, and text with no Material above it is drawn with
      // Flutter's yellow "missing Material" underline.
      child: Material(
        color: AppColors.bgDeep,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DesktopRail(
              currentBranch: currentBranch,
              onBranch: onBranch ?? (_) {},
              canCollapse: mode == DesktopMode.wide,
            ),
            _MiddleColumn(
              width: middle,
              faces: faces,
              list: MediaQuery(
                data: media.copyWith(size: Size(listWidth, media.size.height)),
                child: list,
              ),
            ),
            ColoredBox(
              color: AppColors.glass(0.10),
              child: const SizedBox(width: 1),
            ),
            Expanded(
              child: MediaQuery(
                data: media.copyWith(
                  size: Size(detailWidth, media.size.height),
                ),
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
        ),
      ),
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

/// The column between the rail and the chat: the shell, or the faces over it.
///
/// It used to swap one for the other, and switching tabs with the list folded
/// made the column jump from 76 to 360 px in one frame with the bar inside it
/// blinking out and back ("бар пропадає"). Now the width eases and the faces
/// fade over the list. The shell is never taken out of the tree — it holds the
/// tabs' navigators, and remounting it would throw away where each tab was.
class _MiddleColumn extends StatelessWidget {
  const _MiddleColumn({
    required this.width,
    required this.faces,
    required this.list,
  });

  final double width;
  final bool faces;
  final Widget list;

  static const Duration duration = Duration(milliseconds: 240);
  static const Curve curve = Curves.easeOutCubic;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: duration,
      curve: curve,
      width: width,
      child: ClipRect(
        child: Stack(
          children: [
            // Laid out at full width always, and cut by the column: the list
            // does not re-flow through every width on the way.
            OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: DesktopSplitView.listWidth,
              maxWidth: DesktopSplitView.listWidth,
              child: IgnorePointer(ignoring: faces, child: list),
            ),
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !faces,
                child: AnimatedOpacity(
                  duration: duration,
                  curve: curve,
                  opacity: faces ? 1 : 0,
                  child: const _ChatFaces(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Nothing open yet: the backdrop, and one line saying what to do.
class _EmptyPane extends StatelessWidget {
  const _EmptyPane();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AuroraBackground(
      child: Center(
        child: Container(
          key: const ValueKey(DesktopSplitView.emptyHint),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.bgDeep.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            t.desktopPickChat,
            style: TextStyle(
              color: AppColors.brandPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// The chat list as a column of faces, for a window too narrow for names.
class _ChatFaces extends ConsumerWidget {
  const _ChatFaces();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(visibleChatsProvider);
    final open = ref.watch(desktopOpenChatProvider);
    return ColoredBox(
      color: AppColors.bgDeep.withValues(alpha: 0.55),
      child: Column(
        children: [
          const SizedBox(height: 10),
          IconButton(
            icon: Icon(Icons.search_rounded, color: AppColors.textOnGlass),
            onPressed: () => context.push('/search'),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: chats.length,
              itemBuilder: (context, i) {
                final chat = chats[i];
                final selected = open?.peerId == chat.peerId;
                return Tooltip(
                  message: chat.peerName,
                  waitDuration: const Duration(milliseconds: 400),
                  child: InkWell(
                    onTap: () => openChat(context, ref, chat),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      color: selected
                          ? AppColors.brandPrimary.withValues(alpha: 0.25)
                          : null,
                      child: Center(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            PeerAvatar(
                              peerId: chat.peerId,
                              label: chat.peerName,
                              size: 48,
                            ),
                            if (chat.unreadCount > 0)
                              Positioned(
                                right: -4,
                                bottom: -2,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.brandPrimary,
                                    borderRadius: BorderRadius.circular(9),
                                  ),
                                  child: Text(
                                    chat.unreadCount > 99
                                        ? '99+'
                                        : '${chat.unreadCount}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
