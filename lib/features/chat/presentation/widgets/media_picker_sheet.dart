import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../../core/theme/colors.dart';

/// Telegram-style in-app photo picker: a grid of the device's photos with
/// multi-select and a numbered selection order, returning the chosen
/// [AssetEntity]s to the caller (which downscales + sends each). Replaces the
/// one-at-a-time system picker so several photos go out in one action.
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
    final remaining = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    // Fetch the next page before the user reaches the bottom, so scrolling
    // doesn't visibly stop at the page boundary.
    if (remaining < 800) unawaited(_loadMore());
  }

  Future<void> _load() async {
    try {
      final perm = await PhotoManager.requestPermissionExtend();
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
    return SafeArea(
      child: SizedBox(
        height: media.size.height * 0.7,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Send photos',
              style: TextStyle(
                color: AppColors.textOnGlass,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(child: _body()),
            _sendBar(),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.brandPrimary),
      );
    }
    if (_perm != null && !_perm!.hasAccess) {
      return _message(
        'Photo access is off',
        'Grant photo access to pick images from your gallery.',
        action: 'Open settings',
        onAction: PhotoManager.openSetting,
      );
    }
    if (_assets.isEmpty) {
      return _message('No photos', 'There are no images on this device.');
    }
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 3,
        crossAxisSpacing: 3,
      ),
      itemCount: _assets.length,
      itemBuilder: (_, i) => _Thumb(
        // Keyed by asset id so the element (and its decoded thumbnail) follows
        // its photo instead of its grid slot as pages are appended.
        key: ValueKey<String>(_assets[i].id),
        asset: _assets[i],
        order: _selected.indexOf(_assets[i]),
        onTap: () => _toggle(_assets[i]),
      ),
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
              : () => Navigator.of(context).pop<List<AssetEntity>>(
                    List<AssetEntity>.from(_selected),
                  ),
          child: Text(n == 0 ? 'Select photos' : 'Send $n'),
        ),
      ),
    );
  }

  Widget _message(String title, String hint,
      {String? action, VoidCallback? onAction,}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title,
                style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,),),
            const SizedBox(height: 6),
            Text(hint,
                textAlign: TextAlign.center,
                style:
                    TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),),
            if (action != null) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: onAction,
                child: Text(action,
                    style: const TextStyle(color: AppColors.brandPrimary),),
              ),
            ],
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
  late Future<Uint8List?> _thumb = widget.asset
      .thumbnailDataWithSize(const ThumbnailSize.square(240));

  @override
  void didUpdateWidget(covariant _Thumb old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id) {
      _thumb = widget.asset
          .thumbnailDataWithSize(const ThumbnailSize.square(240));
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
          if (selected)
            Container(color: Colors.black.withValues(alpha: 0.35)),
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
