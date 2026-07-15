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
  PermissionState? _perm;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
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
      );
      if (paths.isNotEmpty) {
        final assets = await paths.first.getAssetListPaged(page: 0, size: 300);
        _assets.addAll(assets);
      }
    } catch (_) {
      // Any failure falls through to the empty / no-access state.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
      padding: const EdgeInsets.symmetric(horizontal: 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 3,
        crossAxisSpacing: 3,
      ),
      itemCount: _assets.length,
      itemBuilder: (_, i) => _Thumb(
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

class _Thumb extends StatelessWidget {
  const _Thumb({required this.asset, required this.order, required this.onTap});

  final AssetEntity asset;

  /// Index in the selection list, or -1 when unselected.
  final int order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selected = order >= 0;
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: asset.thumbnailDataWithSize(const ThumbnailSize.square(240)),
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
                      '${order + 1}',
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
