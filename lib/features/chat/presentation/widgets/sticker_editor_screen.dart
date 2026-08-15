import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/routing/page_transitions.dart';
import '../../../../core/theme/colors.dart';
import '../../../../l10n/app_localizations.dart';
import 'image_editor.dart';

Future<Uint8List?> openStickerEditor(
  BuildContext context,
  Uint8List source,
) {
  return Navigator.of(context, rootNavigator: true).push<Uint8List>(
    mediaRoute<Uint8List>(
      (_) => StickerEditorScreen(source: source),
    ),
  );
}

class StickerEditorScreen extends StatefulWidget {
  const StickerEditorScreen({super.key, required this.source});

  final Uint8List source;

  @override
  State<StickerEditorScreen> createState() => _StickerEditorScreenState();
}

class _StickerEditorScreenState extends State<StickerEditorScreen> {
  final TransformationController _viewer = TransformationController();
  late Uint8List _bytes;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _bytes = widget.source;
  }

  @override
  void dispose() {
    _viewer.dispose();
    super.dispose();
  }

  Future<void> _openTools() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final edited = await openImageEditor(context, _bytes);
      if (edited == null || !mounted) return;
      setState(() {
        _bytes = edited;
        _viewer.value = Matrix4.identity();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _confirm() {
    if (_busy) return;
    Navigator.of(context).pop(_bytes);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 64,
              child: Row(
                children: [
                  const SizedBox(width: 6),
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    iconSize: 30,
                    color: AppColors.textOnGlass,
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t.stickerCreate,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textOnGlass,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.34),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.glass(0.10)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: InteractiveViewer(
                      transformationController: _viewer,
                      minScale: 0.8,
                      maxScale: 6,
                      boundaryMargin: const EdgeInsets.all(80),
                      child: Center(
                        child: Image.memory(
                          _bytes,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 18),
              child: Row(
                children: [
                  Expanded(
                    child: _StickerToolsBar(
                      busy: _busy,
                      onEdit: _openTools,
                    ),
                  ),
                  const SizedBox(width: 18),
                  _ConfirmButton(busy: _busy, onTap: _confirm),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StickerToolsBar extends StatelessWidget {
  const _StickerToolsBar({required this.busy, required this.onEdit});

  final bool busy;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      decoration: BoxDecoration(
        color: AppColors.pane(0.90),
        borderRadius: BorderRadius.circular(29),
        border: Border.all(color: AppColors.glass(0.16)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ToolButton(
            icon: Icons.crop_rotate_rounded,
            onTap: busy ? null : onEdit,
          ),
          _ToolButton(
            icon: Icons.brush_rounded,
            onTap: busy ? null : onEdit,
          ),
          _ToolButton(
            icon: Icons.tune_rounded,
            onTap: busy ? null : onEdit,
          ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon),
      iconSize: 26,
      color: AppColors.textOnGlass,
      splashRadius: 26,
    );
  }
}

class _ConfirmButton extends StatelessWidget {
  const _ConfirmButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 62,
      height: 58,
      child: Material(
        color: AppColors.brandPrimary,
        borderRadius: BorderRadius.circular(29),
        child: InkWell(
          onTap: busy ? null : onTap,
          borderRadius: BorderRadius.circular(29),
          child: Center(
            child: busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.6,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 34,
                  ),
          ),
        ),
      ),
    );
  }
}
