import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/widgets/glass_sheet.dart';
import '../../data/reaction_emoji_controller.dart';
import 'emoji_catalog.dart';

/// Open the full emoji sheet and resolve to the chosen emoji, or null if it was
/// dismissed.
///
/// `useRootNavigator` because the caller is usually the message long-press
/// popup, which is itself a route: pushing onto the same navigator would put
/// the sheet behind the popup it was opened from.
Future<String?> showEmojiPicker(BuildContext context, {String? title}) {
  return showGlassSheet<String>(
    context: context,
    useRootNavigator: true,
    builder: (_) => EmojiPickerSheet(title: title),
  );
}

/// Every emoji the system can draw, grouped and tabbed.
///
/// Reactions used to be six emoji and nothing else. This is the "and nothing
/// else" removed: the strip on the long-press menu stays (it is faster, and it
/// learns what you use), and the last chip on it opens this.
class EmojiPickerSheet extends ConsumerWidget {
  const EmojiPickerSheet({super.key, this.title});

  /// Why the sheet is open, when it is not obvious. Naming a sticker is the
  /// case: the same grid, asked for a different reason.
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = MediaQuery.of(context);
    return SafeArea(
      child: SizedBox(
        height: media.size.height * 0.6,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.glass(0.24),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (title case final label?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Expanded(
              child: EmojiPane(
                onPick: (emoji) => Navigator.of(context).pop(emoji),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The keyboard itself: recents on top, one category at a time, and the bar
/// that switches between them.
///
/// Public and callback-driven because it is used twice now — the sheet above,
/// which closes on a pick because a reaction is one choice, and the composer's
/// panel, which stays open because typing emoji is several.
class EmojiPane extends ConsumerStatefulWidget {
  const EmojiPane({super.key, required this.onPick, this.showRecents = true});

  final ValueChanged<String> onPick;

  /// The six the reaction strip already offers, repeated at the top.
  final bool showRecents;

  @override
  ConsumerState<EmojiPane> createState() => _EmojiPaneState();
}

class _EmojiPaneState extends ConsumerState<EmojiPane> {
  int _group = 0;

  /// One controller per rebuild would jump the grid back to the top every time
  /// a category is tapped — which is what the tap is *for* in the other
  /// direction, so it has to be deliberate rather than accidental.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recents = ref.watch(reactionEmojiControllerProvider);
    final group = EmojiCatalog.groups[_group];
    return Column(
      children: [
        if (widget.showRecents && recents.isNotEmpty)
          _RecentRow(recents: recents, onPick: widget.onPick),
        Expanded(
          child: GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 52,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            itemCount: group.emoji.length,
            itemBuilder: (_, i) => _EmojiCell(
              emoji: group.emoji[i],
              onTap: () => widget.onPick(group.emoji[i]),
            ),
          ),
        ),
        _CategoryBar(
          selected: _group,
          onSelect: (i) {
            setState(() => _group = i);
            if (_scroll.hasClients) _scroll.jumpTo(0);
          },
        ),
      ],
    );
  }
}

/// The six the strip already offers, repeated at the top of the sheet. Cheap to
/// show and it saves the trip through a category for the common case, which is
/// reacting with something you have reacted with before.
class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.recents, required this.onPick});

  final List<String> recents;
  final void Function(String emoji) onPick;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: Row(
        children: [
          for (final emoji in recents)
            _EmojiCell(emoji: emoji, onTap: () => onPick(emoji)),
        ],
      ),
    );
  }
}

class _EmojiCell extends StatelessWidget {
  const _EmojiCell({required this.emoji, required this.onTap});

  final String emoji;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Center(
          child: Text(emoji, style: const TextStyle(fontSize: 26)),
        ),
      ),
    );
  }
}

class _CategoryBar extends StatelessWidget {
  const _CategoryBar({required this.selected, required this.onSelect});

  final int selected;
  final void Function(int index) onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.glass(0.10))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          for (var i = 0; i < EmojiCatalog.groups.length; i++)
            IconButton(
              onPressed: () => onSelect(i),
              iconSize: 21,
              visualDensity: VisualDensity.compact,
              icon: Icon(
                EmojiCatalog.groups[i].icon,
                color: i == selected
                    ? AppColors.brandPrimary
                    : AppColors.textOnGlassDim,
              ),
            ),
        ],
      ),
    );
  }
}
