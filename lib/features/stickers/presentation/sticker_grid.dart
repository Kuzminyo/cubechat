import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../l10n/app_localizations.dart';
import '../data/sticker_library.dart';

/// The stickers this person has kept, as a grid to pick from.
///
/// Empty on a fresh install, and it says so rather than showing a blank
/// rectangle: there is no sticker server to seed it from, so the only thing
/// worth saying is where they come from.
class StickerGrid extends ConsumerWidget {
  const StickerGrid({super.key, required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final stickers = ref.watch(stickerLibraryProvider);

    if (stickers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.emoji_emotions_outlined,
                  size: 34, color: AppColors.textOnGlassFaint),
              const SizedBox(height: 10),
              Text(
                t.stickersEmpty,
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                t.stickersEmptyHint,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textOnGlassDim,
                  fontSize: 12.5,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: stickers.length,
      itemBuilder: (context, i) {
        final path = stickers[i];
        return GestureDetector(
          onTap: () => onPick(path),
          // Removing one is a long press, not a delete button on every tile:
          // the grid is for choosing, and a row of little crosses turns it
          // into a management screen you have to be careful in.
          onLongPress: () => _confirmRemoval(context, ref, t, path),
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
                // Decoded at the size of a cell rather than the size it was
                // kept at — a grid of them is otherwise a screenful of
                // full-resolution bitmaps.
                cacheWidth:
                    (96 * MediaQuery.devicePixelRatioOf(context)).round(),
                errorBuilder: (_, __, ___) => Icon(
                  Icons.broken_image_outlined,
                  color: AppColors.textOnGlassFaint,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

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
