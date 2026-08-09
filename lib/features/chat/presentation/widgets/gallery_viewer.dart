import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../../core/theme/colors.dart';
import '../../../../l10n/app_localizations.dart';

/// What a tap on a thumbnail leads to: the photo, full screen, with the rest of
/// the roll a swipe away.
///
/// The picker grid had exactly one gesture — tap to tick — so there was no way
/// to *look* at a photo before choosing it. Three columns of 240 px squares is
/// enough to tell a sunset from a screenshot and nothing finer, which is the
/// wrong resolution for deciding what to send.
///
/// Selection is handed back through [onToggle] rather than returned at the end,
/// so ticking here and ticking in the grid are the same act on the same list —
/// close the viewer and the grid is already showing what happened. Only the two
/// exits that *leave* the picker come back as a result.
enum GalleryViewerExit {
  /// Send what is selected now.
  send,

  /// Open this photo in the editor, then send it.
  edit,
}

class GalleryViewerResult {
  const GalleryViewerResult(this.exit, this.asset);

  final GalleryViewerExit exit;

  /// The photo that was on screen when the choice was made — the one the editor
  /// should open.
  final AssetEntity asset;
}

class GalleryViewer extends StatefulWidget {
  const GalleryViewer({
    super.key,
    required this.assets,
    required this.initialIndex,
    required this.isSelected,
    required this.orderOf,
    required this.onToggle,
  });

  final List<AssetEntity> assets;
  final int initialIndex;
  final bool Function(AssetEntity) isSelected;

  /// One-based position in the selection, or 0 when unselected — the same
  /// number the grid draws in its badge.
  final int Function(AssetEntity) orderOf;
  final void Function(AssetEntity) onToggle;

  @override
  State<GalleryViewer> createState() => _GalleryViewerState();
}

class _GalleryViewerState extends State<GalleryViewer> {
  late final PageController _pages =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  AssetEntity get _current => widget.assets[_index];

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final selected = widget.isSelected(_current);
    final order = widget.orderOf(_current);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: widget.assets.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) => _Page(asset: widget.assets[i]),
          ),
          SafeArea(
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: t.cancel,
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        '${_index + 1}/${widget.assets.length}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                    // The tick, carrying its position in the selection. Same
                    // badge as the grid, so the number means the same thing in
                    // both places.
                    IconButton(
                      tooltip: t.attachGallery,
                      onPressed: () =>
                          setState(() => widget.onToggle(_current)),
                      icon: Container(
                        width: 26,
                        height: 26,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selected
                              ? AppColors.brandPrimary
                              : Colors.black38,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: selected
                            ? Text(
                                '$order',
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              )
                            : null,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white24),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: () => Navigator.of(context).pop(
                            GalleryViewerResult(
                              GalleryViewerExit.edit,
                              _current,
                            ),
                          ),
                          icon: const Icon(Icons.tune_rounded, size: 18),
                          label: Text(t.chatEditAction),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.brandPrimary,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          // Sends what is ticked; ticks this one first if
                          // nothing is, because arriving here and pressing
                          // Send plainly means "this photo".
                          onPressed: () {
                            if (!widget.isSelected(_current)) {
                              widget.onToggle(_current);
                            }
                            Navigator.of(context).pop(
                              GalleryViewerResult(
                                GalleryViewerExit.send,
                                _current,
                              ),
                            );
                          },
                          child: Text(t.chatSend),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One full-screen photo, zoomable.
///
/// Asked for at a size that fills a phone rather than at its original: a
/// twelve-megapixel photo decoded to look at is 48 MB in the image cache, and
/// the pager keeps neighbours alive.
class _Page extends StatefulWidget {
  const _Page({required this.asset});

  final AssetEntity asset;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  late final Future<Uint8List?> _bytes = widget.asset.thumbnailDataWithSize(
    const ThumbnailSize(1600, 1600),
    quality: 92,
  );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (_, snap) {
        final bytes = snap.data;
        if (bytes == null) {
          return Center(
            child: CircularProgressIndicator(color: AppColors.brandPrimary),
          );
        }
        return InteractiveViewer(
          minScale: 1,
          maxScale: 6,
          child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
        );
      },
    );
  }
}
