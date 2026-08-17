import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/routing/app_shell.dart' show tabSpecFor;
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../data/nav_bar_controller.dart';
import '../data/ui_scale_controller.dart';

/// The bits of the app that are the user's to arrange.
///
/// Pulled out of the App group in Settings, where the interface size sat
/// between the theme picker and the language list as one more row. Those are
/// *preferences* — pick one of a fixed set. This is a different kind of thing:
/// the shape of the app, decided by dragging. Given its own screen so the
/// dragging has room, and so the bar can be edited while you can still see what
/// you are doing to it.
class CustomizeScreen extends ConsumerWidget {
  const CustomizeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final layout = ref.watch(navBarControllerProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: BackButton(color: AppColors.textOnGlass),
        title: Text(
          t.customizeTitle,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
        actions: [
          if (!layout.isDefault)
            TextButton(
              onPressed: () =>
                  ref.read(navBarControllerProvider.notifier).reset(),
              child: Text(
                t.customizeReset,
                style: TextStyle(color: AppColors.brandPrimary, fontSize: 13),
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 140),
          children: [
            const _ScaleCard(),
            const SizedBox(height: 12),
            _NavBarCard(layout: layout),
          ],
        ),
      ),
    );
  }
}

/// How big the app draws itself. Moved here whole from the App group.
///
/// The same build lands visibly larger on one phone than on another — Android's
/// Display size and iOS's Larger Text both feed the text scaler, and neither is
/// visible from inside the app. Following the phone stays the default, because
/// someone who made everything bigger meant this too; the other three are for
/// the phone that was tuned for something else.
///
/// A preview of the actual size sits under the row, so the choice can be made
/// by looking rather than by guessing what "Larger" means here.
class _ScaleCard extends ConsumerWidget {
  const _ScaleCard();

  static String _label(AppLocalizations t, UiScale scale) => switch (scale) {
        UiScale.system => t.profileScaleSystem,
        UiScale.small => t.profileScaleSmall,
        UiScale.normal => t.profileScaleNormal,
        UiScale.large => t.profileScaleLarge,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final current = ref.watch(uiScaleControllerProvider);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.profileScale,
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final scale in UiScale.values) ...[
                if (scale != UiScale.values.first) const SizedBox(width: 8),
                Expanded(
                  child: _Pill(
                    label: _label(t, scale),
                    active: scale == current,
                    onTap: () => ref
                        .read(uiScaleControllerProvider.notifier)
                        .select(scale),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Text(
            t.profileScaleSample,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

/// The bar itself: what is on it, in what order, and what has been put away.
class _NavBarCard extends ConsumerWidget {
  const _NavBarCard({required this.layout});

  final NavBarLayout layout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final controller = ref.read(navBarControllerProvider.notifier);
    final hidden = layout.hidden;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.customizeBarTitle,
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t.customizeBarHint,
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
          ),
          const SizedBox(height: 12),
          _SectionLabel(text: t.customizeBarShown),
          // shrinkWrap because this list is a section of a card inside a page
          // that already scrolls; the drag still works, it simply has no
          // scrolling of its own to do.
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: layout.shown.length,
            onReorder: (from, to) {
              // ReorderableListView reports the target as an insertion index in
              // the *pre-removal* list, so moving an item downward is one place
              // further than where it should end up.
              controller.reorder(from, to > from ? to - 1 : to);
              HapticFeedback.selectionClick();
            },
            proxyDecorator: (child, _, __) => Material(
              color: Colors.transparent,
              child: child,
            ),
            itemBuilder: (context, i) {
              final destination = layout.shown[i];
              final spec = tabSpecFor(destination, t);
              final pinned = destination == NavDestination.chats;
              final last = layout.shown.length <= NavBarController.minimumTabs;
              return _TabRow(
                key: ValueKey(destination),
                index: i,
                icon: spec.activeIcon,
                label: spec.label,
                // Chats cannot leave, and neither can anything else once the
                // bar is down to two — both refusals are explained rather than
                // shown as a dead button.
                trailing: pinned
                    ? Icon(Icons.lock_rounded,
                        size: 16, color: AppColors.textOnGlassFaint)
                    : _RowButton(
                        icon: Icons.remove_circle_outline_rounded,
                        color: last
                            ? AppColors.textOnGlassFaint
                            : AppColors.danger,
                        onTap: () async {
                          final removed = await controller.hide(destination);
                          if (!removed && context.mounted) {
                            showGlassToast(context, t.customizeBarMinimum);
                          }
                        },
                      ),
              );
            },
          ),
          const SizedBox(height: 8),
          _SectionLabel(text: t.customizeBarHidden),
          if (hidden.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 0, 10),
              child: Text(
                t.customizeBarHiddenEmpty,
                style: TextStyle(
                  color: AppColors.textOnGlassFaint,
                  fontSize: 12.5,
                ),
              ),
            )
          else
            for (final destination in hidden)
              _TabRow(
                key: ValueKey('hidden-${destination.name}'),
                icon: tabSpecFor(destination, t).icon,
                label: tabSpecFor(destination, t).label,
                dimmed: true,
                trailing: _RowButton(
                  icon: Icons.add_circle_outline_rounded,
                  color: AppColors.brandPrimary,
                  onTap: () => controller.show(destination),
                ),
              ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 2),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            color: AppColors.textOnGlassFaint,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      );
}

/// One destination, on the bar or off it.
class _TabRow extends StatelessWidget {
  const _TabRow({
    super.key,
    required this.icon,
    required this.label,
    required this.trailing,
    this.index,
    this.dimmed = false,
  });

  final IconData icon;
  final String label;
  final Widget trailing;

  /// Position in the reorderable list, when this row is one that can be
  /// dragged. Null for a hidden tab, which has no order to have.
  final int? index;

  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final ink = dimmed ? AppColors.textOnGlassFaint : AppColors.textOnGlass;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dimmed
                  ? AppColors.glass(0.06)
                  : AppColors.brandPrimary.withValues(alpha: 0.16),
              border: Border.all(
                color: dimmed
                    ? AppColors.glass(0.14)
                    : AppColors.brandPrimary.withValues(alpha: 0.36),
              ),
            ),
            child: Icon(
              icon,
              size: 17,
              color: dimmed ? AppColors.textOnGlassFaint : AppColors.brandPrimary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: ink, fontSize: 14.5),
            ),
          ),
          trailing,
          if (index != null) ...[
            const SizedBox(width: 4),
            // The grip is the only thing that starts a drag, the same rule the
            // pinned chats follow: a row you can drag by anywhere is a row you
            // cannot scroll past.
            ReorderableDragStartListener(
              index: index!,
              child: SizedBox(
                width: 34,
                height: 40,
                child: Icon(
                  Icons.drag_handle_rounded,
                  size: 20,
                  color: AppColors.textOnGlassFaint,
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return Padding(padding: EdgeInsets.zero, child: row);
  }
}

class _RowButton extends StatelessWidget {
  const _RowButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, size: 20, color: color),
      );
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: active ? AppColors.brandGradient : null,
          color: active ? null : AppColors.glass(0.08),
          border: Border.all(
            color: active ? AppColors.glass(0.3) : AppColors.glass(0.15),
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // Fixed, and deliberately not scaled: these four pills are how you
          // *change* the scale, so they have to stay reachable at every
          // setting — including the one that broke the layout.
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            color: AppColors.textOnGlass,
            fontSize: 12.5,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
