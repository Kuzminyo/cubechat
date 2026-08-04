import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../../core/theme/colors.dart';
import 'attach_island.dart';

/// What the picker sheet resolves to when it closes.
///
/// A sealed result rather than a bare `List<AssetEntity>` because the sheet now
/// has two exits — the photo grid and the camera tile — and the caller drives a
/// different flow for each (batch-send vs capture-then-edit).
sealed class MediaPickerResult {
  const MediaPickerResult();
}

/// The user tapped the camera tile; the caller should open the capture screen.
class MediaPickerCamera extends MediaPickerResult {
  const MediaPickerCamera();
}

/// The user chose the Файл category; the caller opens the document picker.
/// The sheet does not open it itself — the picker is a platform sheet of its
/// own, and stacking one modal on another leaves this one orphaned behind it.
class MediaPickerFile extends MediaPickerResult {
  const MediaPickerFile();
}

/// The user confirmed a gallery selection.
class MediaPickerAssets extends MediaPickerResult {
  const MediaPickerAssets(this.assets);
  final List<AssetEntity> assets;
}

/// Telegram-style in-app photo picker: a grid of the device's photos with
/// multi-select and a numbered selection order, plus a camera tile in the first
/// cell. Returns a [MediaPickerResult] — either the camera request or the
/// chosen [AssetEntity]s (which the caller downscales + sends).
class MediaPickerSheet extends StatefulWidget {
  const MediaPickerSheet({super.key});

  @override
  State<MediaPickerSheet> createState() => _MediaPickerSheetState();
}

class _MediaPickerSheetState extends State<MediaPickerSheet> {
  final List<AssetEntity> _assets = [];
  final List<AssetEntity> _selected = []; // tap order preserved for numbering
  final ScrollController _scroll = ScrollController();
  PermissionState? _perm;
  bool _loading = true;

  /// Newest first. photo_manager applies no ordering of its own — `orders`
  /// defaults to an empty list, which leaves the platform's own order in
  /// place, and on Android that is oldest-first. The gallery therefore opened
  /// on photos from years ago.
  static final FilterOptionGroup _newestFirst = FilterOptionGroup(
    orders: const [OrderOption(type: OrderOptionType.createDate, asc: false)],
  );

  /// One screen's worth and change. The album is paged in as the grid scrolls
  /// rather than fetched whole: a single 300-asset read (what this used to do)
  /// both truncated large galleries and stalled the sheet on open.
  static const int _pageSize = 120;

  /// The "All" album, held so later pages can be requested from it.
  AssetPathEntity? _album;
  int _page = 0;

  /// Assets the album says it holds. This — not the length of a returned page
  /// — is what decides whether more pages exist: the plugin drops assets that
  /// no longer exist on disk, so a page can come back short with plenty still
  /// to come. Treating that as the end would silently truncate the gallery.
  int _total = 0;
  bool _loadingMore = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    // Fetch the next page before the user reaches the bottom, so scrolling
    // doesn't visibly stop at the page boundary.
    if (remaining < 800) unawaited(_loadMore());
  }

  Future<void> _load() async {
    try {
      // Ask only about images. The default is RequestType.common, which
      // requests photos AND videos — but the manifest declares only
      // READ_MEDIA_IMAGES (this feature sends photos, never video). On Android
      // 13+, where media permissions are per-type, the never-granted video
      // permission drags the aggregate state to "denied", so the sheet showed
      // "Photo access is off" even with photos fully granted. On Android 12 and
      // below a single READ_EXTERNAL_STORAGE covers everything, which is why it
      // only reproduced on some devices. Querying image-only matches what we
      // declare and what we use.
      final perm = await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: RequestType.image,
            mediaLocation: false,
          ),
        ),
      );
      _perm = perm;
      if (!perm.hasAccess) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
        filterOption: _newestFirst,
      );
      if (paths.isNotEmpty) {
        final album = paths.first;
        _album = album;
        _total = await album.assetCountAsync;
        await _loadMore();
      }
    } catch (_) {
      // Any failure falls through to the empty / no-access state.
    } finally {
      if (mounted) setState(() => _loading = false);
      // The grid only exists once _loading clears, so the check inside the
      // first _loadMore ran against a spinner and found no scroll view.
      _ensureScrollable();
    }
  }

  Future<void> _loadMore() async {
    final album = _album;
    if (album == null || _loadingMore || !_hasMore) return;
    _loadingMore = true;
    try {
      final page = await album.getAssetListPaged(page: _page, size: _pageSize);
      // Always advance, even on an empty page: paging is by index, so not
      // moving on would re-request the same page forever.
      _page++;
      _hasMore = _page * _pageSize < _total;
      if (page.isNotEmpty && mounted) {
        setState(() => _assets.addAll(page));
      } else {
        _assets.addAll(page);
      }
    } catch (_) {
      _hasMore = false; // stop retrying a source that's failing
    } finally {
      _loadingMore = false;
    }
    _ensureScrollable();
  }

  /// Keep pulling pages until the grid actually overflows its viewport.
  ///
  /// Paging is driven by scrolling, so a page that comes back too short to
  /// fill the sheet (the plugin drops assets whose files are gone) would leave
  /// nothing to scroll and stall the load with photos still unfetched.
  void _ensureScrollable() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hasMore || _loadingMore || !_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent <= 0) unawaited(_loadMore());
    });
  }

  void _toggle(AssetEntity asset) {
    setState(() {
      if (!_selected.remove(asset)) _selected.add(asset);
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // No surface of its own: the sheet *is* one pane of glass now (see
    // showGlassSheet), so everything in here sits directly on it. A card inside
    // a card was the thing that made this look like a dialog stacked on a
    // plate rather than one island floating over the conversation.
    return SizedBox(
      height: media.size.height * 0.7,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.glass(0.24),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            // Rounded to the island's own corners, so the grid ends where the
            // glass does instead of squaring it off.
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: _body(),
            ),
          ),
          _sendBar(),
          AttachIsland(
            bare: true,
            selected: AttachChoice.gallery,
            onPick: (choice) => switch (choice) {
              AttachChoice.gallery => null,
              AttachChoice.camera =>
                Navigator.of(context).pop(const MediaPickerCamera()),
              AttachChoice.file =>
                Navigator.of(context).pop(const MediaPickerFile()),
            },
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(color: AppColors.brandPrimary),
      );
    }
    if (_perm != null && !_perm!.hasAccess) {
      // No gallery access still lets the camera work — surface both.
      return _message(
        'Photo access is off',
        'Grant photo access to pick images, or take a photo now.',
        action: 'Open settings',
        onAction: PhotoManager.openSetting,
        secondaryAction: 'Take a photo',
        onSecondaryAction: () =>
            Navigator.of(context).pop(const MediaPickerCamera()),
      );
    }
    // itemCount is assets + 1: the first cell is always the camera tile, so the
    // camera is reachable even when the gallery is empty.
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 3,
        crossAxisSpacing: 3,
      ),
      itemCount: _assets.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return _CameraTile(
            onTap: () => Navigator.of(context).pop(const MediaPickerCamera()),
          );
        }
        final asset = _assets[i - 1];
        return _Thumb(
          // Keyed by asset id so the element (and its decoded thumbnail) follows
          // its photo instead of its grid slot as pages are appended.
          key: ValueKey<String>(asset.id),
          asset: asset,
          order: _selected.indexOf(asset),
          onTap: () => _toggle(asset),
        );
      },
    );
  }

  Widget _sendBar() {
    final n = _selected.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.brandPrimary,
            foregroundColor: Colors.black,
            disabledBackgroundColor: AppColors.glassFill,
          ),
          onPressed: n == 0
              ? null
              : () => Navigator.of(context).pop(
                    MediaPickerAssets(List<AssetEntity>.from(_selected)),
                  ),
          child: Text(n == 0 ? 'Select photos' : 'Send $n'),
        ),
      ),
    );
  }

  Widget _message(
    String title,
    String hint, {
    String? action,
    VoidCallback? onAction,
    String? secondaryAction,
    VoidCallback? onSecondaryAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: TextStyle(
                color: AppColors.textOnGlass,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
            ),
            if (secondaryAction != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandPrimary,
                  foregroundColor: Colors.black,
                ),
                onPressed: onSecondaryAction,
                icon: const Icon(Icons.photo_camera, size: 18),
                label: Text(secondaryAction),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: onAction,
                child: Text(
                  action,
                  style: TextStyle(color: AppColors.brandPrimary),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The camera tile that leads the photo grid — tap to open the in-app camera.
class _CameraTile extends StatelessWidget {
  const _CameraTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.glassFill,
          borderRadius: BorderRadius.circular(6),
          border:
              Border.all(color: AppColors.brandPrimary.withValues(alpha: 0.4)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_camera,
                color: AppColors.brandPrimary, size: 26),
            const SizedBox(height: 6),
            Text(
              'Camera',
              style: TextStyle(
                color: AppColors.textOnGlass,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatefulWidget {
  const _Thumb({
    super.key,
    required this.asset,
    required this.order,
    required this.onTap,
  });

  final AssetEntity asset;

  /// Index in the selection list, or -1 when unselected.
  final int order;
  final VoidCallback onTap;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  /// Started once and held, rather than created in build(): selecting a photo
  /// setStates the whole sheet, and a future built inline would re-decode every
  /// visible thumbnail on each tap.
  late Future<Uint8List?> _thumb =
      widget.asset.thumbnailDataWithSize(const ThumbnailSize.square(240));

  @override
  void didUpdateWidget(covariant _Thumb old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id) {
      _thumb =
          widget.asset.thumbnailDataWithSize(const ThumbnailSize.square(240));
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.order >= 0;
    return GestureDetector(
      onTap: widget.onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: _thumb,
            builder: (_, snap) {
              final bytes = snap.data;
              if (bytes == null) {
                return Container(color: AppColors.glassFill);
              }
              return Image.memory(bytes, fit: BoxFit.cover);
            },
          ),
          if (selected) Container(color: Colors.black.withValues(alpha: 0.35)),
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? AppColors.brandPrimary : Colors.black38,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              alignment: Alignment.center,
              child: selected
                  ? Text(
                      '${widget.order + 1}',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
