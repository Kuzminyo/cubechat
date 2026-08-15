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
                    onLongPress: () => _confirmRemoval(context, ref, t, path),
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
  Future<void> _pickBuiltin(BuildContext context, String glyph) async {
    final path = await BuiltinStickers.materialize(glyph);
    if (path != null) {
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
    required this.onLongPress,
  });

  final String path;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Image.file(
          File(path),
          fit: BoxFit.contain,
          cacheWidth: (104 * MediaQuery.devicePixelRatioOf(context)).round(),
          errorBuilder: (_, __, ___) => Icon(
            Icons.broken_image_outlined,
            color: AppColors.textOnGlassFaint,
          ),
        ),
      ),
    );
  }
}

class _GlyphTile extends StatelessWidget {
  const _GlyphTile({required this.glyph, required this.onTap});

  final String glyph;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: Text(
          glyph,
          style: const TextStyle(fontSize: 44),
          textScaler: TextScaler.noScaling,
        ),
      ),
    );
  }
}
