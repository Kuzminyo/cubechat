import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../data/builtin_stickers.dart';
import '../data/sticker_library.dart';
import '../data/sticker_pack.dart';

/// Everything there is to pick from: the ones this person made or kept, and
/// the pack that is here on a fresh install.
///
/// Telegram's sticker picker is not a card grid: the sticker is the control.
/// The cells here therefore stay mostly transparent, with a small creation
/// tile and no heavy backgrounds under every image.
class StickerGrid extends ConsumerWidget {
  const StickerGrid({super.key, required this.onPick, this.onCreate});

  /// A sticker was chosen: the path of the file to send, and the emoji it is
  /// filed under (null for one kept before there were any). Built-in ones are
  /// painted to disk before this fires, so the caller never has to know which
  /// kind it got.
  final void Function(String path, String? emoji) onPick;

  /// Tapped "make one". Null hides the tile — the picker is then read-only.
  final VoidCallback? onCreate;

  static const _columns = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final mine = ref.watch(stickerLibraryProvider);
    final mineCount = mine.length + (onCreate == null ? 0 : 1);

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        if (mineCount > 0) ...[
          _header(t.stickersMine),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _columns,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  if (onCreate != null && i == 0) {
                    return _CreateTile(
                        label: t.stickerCreate, onTap: onCreate!);
                  }
                  final stickerIndex = i - (onCreate == null ? 0 : 1);
                  final path = mine[stickerIndex];
                  return _KeptTile(
                    path: path,
                    onTap: () => onPick(
                      path,
                      ref.read(stickerLibraryProvider.notifier).emojiFor(path),
                    ),
                    onRemove: () => _confirmRemoval(context, ref, t, path),
                  );
                },
                childCount: mineCount,
              ),
            ),
          ),
        ],
        _header(t.stickersStarterPack),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 18),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _columns,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final name = BuiltinStickers.names[i];
                return _PackTile(
                  name: name,
                  onTap: () => _pickBuiltin(context, name),
                );
              },
              childCount: BuiltinStickers.names.length,
            ),
          ),
        ),
      ],
    );
  }

  /// Copy it out of the bundle, then hand the caller a path like any other.
  Future<void> _pickBuiltin(BuildContext context, String name) async {
    final path = await BuiltinStickers.materialize(name);
    if (path != null) {
      onPick(path, BuiltinStickers.emojiFor(name));
      return;
    }
    if (!context.mounted) return;
    showGlassToast(
      context,
      AppLocalizations.of(context).stickerFailed,
      tone: ToastTone.danger,
    );
  }

  Widget _header(String label) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 7),
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
        ),
      );

  Future<void> _confirmRemoval(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations t,
    String path,
  ) async {
    final gone = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.bgTop,
      builder: (sheet) => SafeArea(
        child: ListTile(
          leading: Icon(Icons.delete_outline_rounded, color: AppColors.danger),
          title: Text(
            t.stickerForget,
            style: TextStyle(color: AppColors.textOnGlass),
          ),
          onTap: () => Navigator.of(sheet).pop(true),
        ),
      ),
    );
    if (gone == true) {
      await ref.read(stickerLibraryProvider.notifier).forget(path);
    }
  }
}

class _CreateTile extends StatelessWidget {
  const _CreateTile({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Center(
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.brandPrimary.withValues(alpha: 0.14),
                border: Border.all(
                  color: AppColors.brandPrimary.withValues(alpha: 0.34),
                ),
              ),
              child: Icon(
                Icons.add_rounded,
                color: AppColors.brandPrimary,
                size: 34,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KeptTile extends StatelessWidget {
  const _KeptTile({
    required this.path,
    required this.onTap,
    required this.onRemove,
  });

  final String path;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      // Long-press still removes, for the muscle memory it already built; the
      // corner button is the visible version of the same thing, for everyone
      // who never learned the gesture.
      onLongPress: onRemove,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(5),
            child: Image.file(
              File(path),
              fit: BoxFit.contain,
              cacheWidth:
                  (104 * MediaQuery.devicePixelRatioOf(context)).round(),
              errorBuilder: (_, __, ___) => Icon(
                Icons.broken_image_rounded,
                color: AppColors.textOnGlassFaint,
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: GestureDetector(
              // Its own tap target, so removing one does not send it: without
              // this the badge would sit under the tile's onTap and deleting a
              // sticker would fire it into the chat on the way out.
              behavior: HitTestBehavior.opaque,
              onTap: onRemove,
              child: Container(
                margin: const EdgeInsets.all(2),
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close_rounded,
                  size: 13,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One sticker in the shipped pack, drawn as a still.
///
/// The still and not the animation, and that is the whole point of shipping
/// two files. Seventy-two loops running at once so somebody can choose one is
/// the shape of thing this codebase keeps measuring and taking back out: every
/// frame of every cell would be decoded, uploaded and composited for as long as
/// the sheet is open, on a screen where nothing has happened yet. The picture
/// moves when it has been sent, which is when there is one of it and somebody
/// is reading it.
class _PackTile extends StatelessWidget {
  const _PackTile({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Decoded at the size it is drawn. A cell is a third of a phone's width;
    // the file is 176 square and would otherwise be decoded at full size into
    // memory seventy-two times over — the cost this app has already paid once,
    // for gallery thumbnails, and written down.
    final side = MediaQuery.of(context).size.width / 3;
    final pixels = (side * MediaQuery.devicePixelRatioOf(context)).round();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Image.asset(
          StickerPack.still(name),
          cacheWidth: pixels,
          cacheHeight: pixels,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}
