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
                      icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
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
                // The way on. Looking at a photo full screen used to be a dead
                // end — back to the grid, find the tick, then find send — and
                // the two exits this screen already declared were never wired
                // to anything. Forward goes where the send arrow in the grid
                // goes: the screen with the caption box.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      if (_current.type != AssetType.video)
                        _Round(
                          icon: Icons.brush_rounded,
                          tooltip: t.editorToolDraw,
                          onTap: () => Navigator.of(context).pop(
                            GalleryViewerResult(
                              GalleryViewerExit.edit,
                              _current,
                            ),
                          ),
                        ),
                      const Spacer(),
                      _Round(
                        icon: Icons.arrow_forward_rounded,
                        tooltip: t.chatSend,
                        filled: true,
                        onTap: _forward,
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

  /// On to the caption screen, taking this photo whether or not it was ticked.
  ///
  /// Ticking it first rather than passing it separately, so the grid behind
  /// and the selection agree — the count in the badge is the count that gets
  /// sent, which is the whole contract of this screen's tick.
  void _forward() {
    if (!widget.isSelected(_current)) widget.onToggle(_current);
    Navigator.of(context)
        .pop(GalleryViewerResult(GalleryViewerExit.send, _current));
  }
}

/// A glyph in a disc, over a photograph.
class _Round extends StatelessWidget {
  const _Round({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: filled
            ? AppColors.brandPrimary
            : Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(
              icon,
              size: 22,
              color: filled ? AppColors.bgDeep : Colors.white,
            ),
          ),
        ),
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
