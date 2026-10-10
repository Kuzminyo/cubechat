import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/routing/app_shell.dart' show tabSpecFor;
import '../../core/theme/colors.dart';
import '../../l10n/app_localizations.dart';
import '../chats/presentation/chats_list_screen.dart' show visibleChatsProvider;
import '../profile/data/nav_bar_controller.dart';

/// Whether the chat list beside the rail is folded down to its faces.
///
/// Asked for as "в чатах можно будет оставлять только кружки аватарок": the
/// conversation gets the room, and the people are still one click away.
final desktopListCollapsedProvider = StateProvider<bool>((_) => false);

/// The phone's tab bar, stood on its end down the left of a computer window:
/// the same tabs, in the same order the person arranged them, with the unread
/// count on Chats. At the bottom, on Chats, the switch that folds the list
/// down to its faces.
class DesktopRail extends ConsumerWidget {
  const DesktopRail({
    super.key,
    required this.currentBranch,
    required this.onBranch,
    this.canCollapse = true,
  });

  /// The shell branch on show, and how to switch it.
  final int currentBranch;
  final ValueChanged<int> onBranch;

  /// False where the window is too narrow for names anyway and the list is
  /// faces regardless.
  final bool canCollapse;

  static const double width = 76;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final layout = ref.watch(navBarControllerProvider);
    final unread = ref.watch(
      visibleChatsProvider.select(
        (chats) => chats.where((c) => c.unreadCount > 0).length,
      ),
    );
    final collapsed = ref.watch(desktopListCollapsedProvider);
    final onChats = currentBranch == NavDestination.chats.branch;

    return ColoredBox(
      color: AppColors.bgDeep.withValues(alpha: 0.72),
      child: SizedBox(
        width: width,
        child: Column(
          children: [
            const SizedBox(height: 12),
            for (final d in layout.shown)
              _RailItem(
                icon: d.branch == currentBranch
                    ? tabSpecFor(d, t).activeIcon
                    : tabSpecFor(d, t).icon,
                label: tabSpecFor(d, t).label,
                badge: tabSpecFor(d, t).showsUnread ? unread : 0,
                active: d.branch == currentBranch,
                onTap: () => onBranch(d.branch),
              ),
            const Spacer(),
            if (onChats && canCollapse)
              IconButton(
                tooltip:
                    collapsed ? t.desktopListExpand : t.desktopListCollapse,
                icon: Icon(
                  collapsed
                      ? Icons.keyboard_double_arrow_right_rounded
                      : Icons.keyboard_double_arrow_left_rounded,
                  color: AppColors.textOnGlassDim,
                ),
                onPressed: () => ref
                    .read(desktopListCollapsedProvider.notifier)
                    .state = !collapsed,
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.badge = 0,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final fg = active ? AppColors.brandPrimary : AppColors.textOnGlassDim;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 52,
                  height: 32,
                  decoration: BoxDecoration(
                    color: active
                        ? AppColors.brandPrimary.withValues(alpha: 0.18)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: fg, size: 24),
                ),
                if (badge > 0)
                  Positioned(
                    right: -4,
                    top: -6,
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
                        badge > 99 ? '99+' : '$badge',
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: fg,
                fontSize: 11.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
