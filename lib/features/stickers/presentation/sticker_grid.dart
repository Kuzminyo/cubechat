import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../data/builtin_stickers.dart';
import '../data/sticker_library.dart';

/// Everything there is to pick from: the ones this person made or kept, and
/// the pack that is here on a fresh install.
///
/// It used to be the kept ones alone, which on a new phone is an empty
/// rectangle and a sentence explaining that stickers come from somewhere else.
/// The starter pack is drawn on the spot — see [BuiltinStickers] — so the
/// picker has something in it from the first tap, and "make one of your own" is
/// the first cell rather than a feature nobody could find.
class StickerGrid extends ConsumerWidget {
  const StickerGrid({super.key, required this.onPick, this.onCreate});

  /// A sticker was chosen: the path of the file to send, and the emoji it is
  /// filed under (null for one kept before there were any). Built-in ones are
  /// painted to disk before this fires, so the caller never has to know which
  /// kind it got.
  final void Function(String path, String? emoji) onPick;

  /// Tapped "make one". Null hides the tile — the picker is then read-only,
  /// which is what a caller that has nowhere to run a gallery picker wants.
  final VoidCallback? onCreate;

  static const _columns = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final mine = ref.watch(stickerLibraryProvider);

    return CustomScrollView(
      slivers: [
        if (onCreate != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: _CreateButton(label: t.stickerCreate, onTap: onCreate!),
            ),
          ),
        if (mine.isNotEmpty) ...[
          _header(t.stickersMine),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _columns,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _KeptTile(
                  path: mine[i],
                  onTap: () => onPick(
                    mine[i],
                    ref.read(stickerLibraryProvider.notifier).emojiFor(mine[i]),
                  ),
                  onLongPress: () => _confirmRemoval(context, ref, t, mine[i]),
                ),
                childCount: mine.length,
              ),
            ),
          ),
        ],
        _header(t.stickersStarterPack),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _columns,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final glyph = BuiltinStickers.glyphs[i];
                return _GlyphTile(
                  glyph: glyph,
                  onTap: () => _pickBuiltin(context, glyph),
                );
              },
              childCount: BuiltinStickers.glyphs.length,
            ),
          ),
        ),
      ],
    );
  }

  /// Paint the glyph into a file, then hand the caller a path like any other.
  ///
  /// Nothing is shown while it happens: it is one canvas and one PNG encode of
  /// a 320-pixel square, which lands inside a frame or two, and a spinner that
  /// flashes for 30 ms reads as a fault rather than as progress.
  Future<void> _pickBuiltin(BuildContext context, String glyph) async {
    final path = await BuiltinStickers.materialize(glyph);
    if (path != null) {
      // A pack sticker *is* its emoji, so that is what it is filed under.
      onPick(path, glyph);
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
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
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
          leading: Icon(Icons.delete_outline, color: AppColors.danger),
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

/// The way in to making one, at the top where it is read first.
class _CreateButton extends StatelessWidget {
  const _CreateButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.brandPrimary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.brandPrimary.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.add_photo_alternate_outlined,
                  size: 20, color: AppColors.brandPrimary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: AppColors.brandPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
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

class _KeptTile extends StatelessWidget {
  const _KeptTile({
    required this.path,
    required this.onTap,
    required this.onLongPress,
  });

  final String path;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      // Removing one is a long press, not a delete button on every tile: the
      // grid is for choosing, and a row of little crosses turns it into a
      // management screen you have to be careful in.
      onLongPress: onLongPress,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.glass(0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            // Decoded at the size of a cell rather than the size it was kept
            // at — a grid of them is otherwise a screenful of full-resolution
            // bitmaps.
            cacheWidth: (96 * MediaQuery.devicePixelRatioOf(context)).round(),
            errorBuilder: (_, __, ___) => Icon(
              Icons.broken_image_outlined,
              color: AppColors.textOnGlassFaint,
            ),
          ),
        ),
      ),
    );
  }
}

/// A pack entry, drawn as the character it is until somebody picks it.
///
/// Painting all forty-eight to disk to fill a grid would be forty-eight PNG
/// encodes for a sheet that is usually scrolled past; the text is the same
/// glyph from the same font, at a fraction of the cost.
class _GlyphTile extends StatelessWidget {
  const _GlyphTile({required this.glyph, required this.onTap});

  final String glyph;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.glass(0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            glyph,
            style: const TextStyle(fontSize: 34),
            textScaler: TextScaler.noScaling,
          ),
        ),
      ),
    );
  }
}
