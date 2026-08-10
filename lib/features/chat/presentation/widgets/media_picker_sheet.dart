import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/util/ui_activity.dart';
import '../../../../core/widgets/confirm_dialog.dart';
import '../../../../l10n/app_localizations.dart';
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

/// The user chose the Опитування category; the caller opens the poll composer.
/// Channels only — see [AttachIsland.allowPoll].
class MediaPickerLocation extends MediaPickerResult {
  const MediaPickerLocation();
}

/// One photo, to be opened in the editor and then sent.
///
/// Carries the asset rather than its bytes: loading and editing already have a
/// path in the chat screen (the camera goes down it), and handing over an
/// [AssetEntity] keeps the picker out of the business of decoding.
class MediaPickerEdit extends MediaPickerResult {
  const MediaPickerEdit(this.asset);

  final AssetEntity asset;
}

class MediaPickerPoll extends MediaPickerResult {
  const MediaPickerPoll();
}

/// The user confirmed a gallery selection.
class MediaPickerAssets extends MediaPickerResult {
  const MediaPickerAssets(this.assets, {this.caption});

  final List<AssetEntity> assets;
  final String? caption;
}

/// Telegram-style in-app photo picker: a grid of the device's photos with
/// multi-select and a numbered selection order, plus a camera tile in the first
/// cell. Returns a [MediaPickerResult] — either the camera request or the
/// chosen [AssetEntity]s (which the caller downscales + sends).
class MediaPickerSheet extends StatefulWidget {
  const MediaPickerSheet({
    super.key,
    this.allowFiles = true,
    this.allowPoll = false,
    this.allowCaption = true,
  });

  /// See [AttachIsland.allowFiles] — a channel takes photos but not documents.
  final bool allowFiles;

  /// See [AttachIsland.allowPoll] — a channel starts votes, a 1:1 does not.
  final bool allowPoll;

  /// False when this picker is selecting an avatar, cover, or wallpaper.
  final bool allowCaption;

  @override
  State<MediaPickerSheet> createState() => _MediaPickerSheetState();
}

class _MediaPickerSheetState extends State<MediaPickerSheet> {
  final List<AssetEntity> _assets = [];
  final List<AssetEntity> _selected = []; // tap order preserved for numbering
  final ScrollController _scroll = ScrollController();
  final TextEditingController _caption = TextEditingController();

  bool _allowPop = false;
  bool _confirmingDiscard = false;
  PermissionState? _perm;
  bool _loading = true;

  /// Newest first. photo_manager applies no ordering of its own — `orders`
  /// defaults to an empty list, which leaves the platform's own order in
  /// place, and on Android that is oldest-first. The gallery therefore opened
  /// on photos from years ago.
  /// Built per open, and with the creation-time condition explicitly ignored.
  ///
  /// Both halves matter, and together they are why a screenshot taken while
  /// the app was running only showed up after a full restart.
  /// [FilterOptionGroup] defaults `createTimeCond` to `DateTimeCond.def()`,
  /// whose `max` is `DateTime.now()` **evaluated when the group is
  /// constructed** — and this used to be a `static final`, so that ceiling was
  /// frozen at the first open of the session. Every photo taken afterwards was
  /// newer than the filter's idea of "now" and was quietly excluded.
  static FilterOptionGroup _newestFirst() => FilterOptionGroup(
        orders: const [
          OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
        createTimeCond: DateTimeCond.def().copyWith(ignore: true),
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
    _caption.dispose();
    UiActivity.instance.setScrolling(false);
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
        filterOption: _newestFirst(),
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
      // Either signal is enough to keep going, because either one can be wrong
      // on its own. The count can come back short of what the album really
      // holds — some devices report the count for one bucket while paging reads
      // another — and that alone stopped the grid dead at 120 photos with no
      // way to scroll to anything older. A page returning full is the other
      // direction: there is at least one more index to ask for.
      _hasMore = _page * _pageSize < _total || page.length >= _pageSize;
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

  void _close([MediaPickerResult? result]) {
    if (!mounted || _allowPop) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  void _completeSelection() {
    if (_selected.isEmpty) return;
    final text = _caption.text.trim();
    _close(
      MediaPickerAssets(
        List<AssetEntity>.from(_selected),
        caption: text.isEmpty ? null : text,
      ),
    );
  }

  Future<void> _confirmDiscard() async {
    if (_confirmingDiscard || _selected.isEmpty) return;
    _confirmingDiscard = true;
    final t = AppLocalizations.of(context);
    final discard = await confirmAction(
      context,
      title: t.mediaDiscardTitle,
      message: t.mediaDiscardMessage,
      confirmLabel: t.mediaDiscardConfirm,
    );
    _confirmingDiscard = false;
    if (discard && mounted) _close();
  }

  /// Full screen, from the photo that was tapped, with the rest of the roll a
  /// swipe away.
  ///
  /// Selection is passed in by callback rather than returned, so ticking in
  /// there and ticking in the grid are one act on one list — the grid is
  /// already up to date when the viewer closes. Only leaving the picker
  /// entirely comes back as a result.
  /// Straight to the editor, no detour.
  ///
  /// Tapping a photo used to open a full-screen viewer offering "send" and
  /// "edit". It sat between wanting to send a photo and sending it: the grid
  /// already shows the photo, and the caption bar already sends it, so the
  /// viewer's two buttons were a second copy of decisions the sheet had made
  /// available a tap earlier. Tapping selects again; editing is a long press.
  void _openEditor(AssetEntity asset) => _close(MediaPickerEdit(asset));

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // No surface of its own: the sheet *is* one pane of glass now (see
    // showGlassSheet), so everything in here sits directly on it. A card inside
    // a card was the thing that made this look like a dialog stacked on a
    // plate rather than one island floating over the conversation.
    return PopScope<MediaPickerResult>(
      canPop: _allowPop || _selected.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmDiscard());
      },
      child: SizedBox(
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
              allowFiles: widget.allowFiles,
              allowPoll: widget.allowPoll,
              selected: AttachChoice.gallery,
              onPick: (choice) => switch (choice) {
                AttachChoice.gallery => null,
                AttachChoice.camera => _close(const MediaPickerCamera()),
                AttachChoice.file => _close(const MediaPickerFile()),
                AttachChoice.poll => _close(const MediaPickerPoll()),
                AttachChoice.location => _close(const MediaPickerLocation()),
              },
            ),
          ],
        ),
      ),
    );
  }

  bool _onGalleryScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      UiActivity.instance.setScrolling(true);
    } else if (notification is ScrollEndNotification) {
      UiActivity.instance.setScrolling(false);
    }
    return false;
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
        onSecondaryAction: () => _close(const MediaPickerCamera()),
      );
    }
    // itemCount is assets + 1: the first cell is always the camera tile, so the
    // camera is reachable even when the gallery is empty.
    return NotificationListener<ScrollNotification>(
      onNotification: _onGalleryScroll,
      child: GridView.builder(
        controller: _scroll,
        // Room under the last row for the caption bar, which appears over the
        // grid the moment anything is selected — without it the bottom row of
        // photos sat behind the bar and could not be reached.
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 96),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 3,
          crossAxisSpacing: 3,
        ),
        itemCount: _assets.length + 1,
        itemBuilder: (_, i) {
          if (i == 0) {
            return _CameraTile(
              onTap: () => _close(const MediaPickerCamera()),
            );
          }
          final asset = _assets[i - 1];
          return _Thumb(
            // Keyed by asset id so the element (and its decoded thumbnail) follows
            // its photo instead of its grid slot as pages are appended.
            key: ValueKey<String>(asset.id),
            asset: asset,
            order: _selected.indexOf(asset),
            // Tap selects — anywhere on the cell, control included. Long-press
            // opens the editor for that one photo.
            onTap: () => _toggle(asset),
            onToggle: () => _toggle(asset),
            onLongPress: () => _openEditor(asset),
          );
        },
      ),
    );
  }

  Widget _sendBar() {
    final n = _selected.length;
    if (n == 0) return const SizedBox(height: 8);

    if (!widget.allowCaption) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brandPrimary,
              foregroundColor: Colors.black,
            ),
            onPressed: _completeSelection,
            child: Text(n == 1 ? 'Select photo' : 'Select $n photos'),
          ),
        ),
      );
    }

    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 5, 5, 5),
        decoration: BoxDecoration(
          color: AppColors.pane(0.76),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: AppColors.glass(0.16)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 18,
              offset: const Offset(0, 8),
              spreadRadius: -10,
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 11),
              child: Icon(
                Icons.sentiment_satisfied_alt_outlined,
                color: AppColors.brandPrimary,
                size: 23,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _caption,
                minLines: 1,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 15,
                ),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 13),
                  hintText: t.mediaCaptionHint,
                  hintStyle: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Semantics(
              button: true,
              label: 'Send $n',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _completeSelection,
                child: SizedBox(
                  width: 52,
                  height: 52,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: AppColors.brandGradient,
                          ),
                          child: const Icon(
                            Icons.send_rounded,
                            color: Colors.black,
                            size: 24,
                          ),
                        ),
                      ),
                      Positioned(
                        top: -5,
                        left: -4,
                        child: Container(
                          constraints: const BoxConstraints(
                            minWidth: 22,
                            minHeight: 22,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.danger,
                            border: Border.all(
                              color: AppColors.bgDeep,
                              width: 2,
                            ),
                          ),
                          child: Text(
                            '$n',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
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
            Icon(Icons.photo_camera, color: AppColors.brandPrimary, size: 26),
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
    required this.onToggle,
    required this.onLongPress,
  });

  final AssetEntity asset;

  /// Index in the selection list, or -1 when unselected.
  final int order;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onLongPress;

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
      onLongPress: widget.onLongPress,
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
            top: 1,
            right: 1,
            child: Semantics(
              button: true,
              selected: selected,
              label: selected ? 'Deselect photo' : 'Select photo',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onToggle,
                child: SizedBox(
                  width: 42,
                  height: 42,
                  child: Center(
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color:
                            selected ? AppColors.brandPrimary : Colors.black45,
                        border: Border.all(color: Colors.white, width: 1.6),
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
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
