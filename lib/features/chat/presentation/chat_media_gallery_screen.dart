import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/colors.dart';
import '../data/messages_controller.dart';
import '../models/message.dart';
import '../../../core/widgets/glass_toast.dart';

/// Telegram-style media browser: every image in a conversation, full-screen and
/// swipeable, with pinch-zoom, save-to-gallery and share. Opened from an image
/// bubble at that image's position; swiping pages through the rest.
class ChatMediaGalleryScreen extends ConsumerStatefulWidget {
  const ChatMediaGalleryScreen({
    super.key,
    required this.chatId,
    required this.initialMessageId,
  });

  final String chatId;
  final String initialMessageId;

  @override
  ConsumerState<ChatMediaGalleryScreen> createState() =>
      _ChatMediaGalleryScreenState();
}

class _ChatMediaGalleryScreenState
    extends ConsumerState<ChatMediaGalleryScreen> {
  late final PageController _controller;
  int _index = 0;
  bool _saving = false;

  /// Snapshot the image list once so paging isn't disturbed if a new message
  /// arrives mid-view; still enough for the common "look through photos" flow.
  late final List<Message> _images = _collectImages();

  List<Message> _collectImages() {
    final msgs = ref.read(messagesControllerProvider)[widget.chatId] ??
        const <Message>[];
    return msgs
        .where(
          (m) =>
              m.kind == MessageKind.image &&
              m.imagePath != null &&
              File(m.imagePath!).existsSync(),
        )
        .toList();
  }

  @override
  void initState() {
    super.initState();
    final start = _images.indexWhere((m) => m.id == widget.initialMessageId);
    _index = start < 0 ? 0 : start;
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Message? get _current =>
      (_index >= 0 && _index < _images.length) ? _images[_index] : null;

  Future<void> _share() async {
    final path = _current?.imagePath;
    if (path == null) return;
    try {
      await Share.shareXFiles([XFile(path)]);
    } catch (e) {
      _toast('Could not share: $e', ok: false);
    }
  }

  Future<void> _save() async {
    final msg = _current;
    final path = msg?.imagePath;
    if (path == null || _saving) return;
    setState(() => _saving = true);
    try {
      final bytes = await File(path).readAsBytes();
      final ext = _extFor(msg!.imageMime, path);
      final result = await SaverGallery.saveImage(
        bytes,
        fileName: 'cubechat_${msg.id}$ext',
        skipIfExists: false,
      );
      _toast(result.isSuccess ? 'Saved to gallery' : 'Save failed',
          ok: result.isSuccess);
    } catch (e) {
      _toast('Save failed: $e', ok: false);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String message, {bool ok = true}) {
    if (!mounted) return;
    showGlassToast(
      context,
      message,
      icon: ok ? Icons.download_done_rounded : null,
      tone: ok ? ToastTone.success : ToastTone.danger,
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = _images.length;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.35),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: count <= 1
            ? null
            : Text(
                '${_index + 1} / $count',
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share, color: Colors.white),
            tooltip: 'Share',
            onPressed: _current == null ? null : _share,
          ),
          IconButton(
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.download, color: Colors.white),
            tooltip: 'Save',
            onPressed: _current == null ? null : _save,
          ),
        ],
      ),
      body: count == 0
          ? _missing()
          : PageView.builder(
              controller: _controller,
              itemCount: count,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) {
                final m = _images[i];
                return InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 8,
                  child: Center(
                    child: Hero(
                      tag: 'image-${m.id}',
                      child: Image.file(
                        File(m.imagePath!),
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => _missing(),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _missing() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.broken_image_outlined,
              color: AppColors.textOnGlassDim,
              size: 56,
            ),
            const SizedBox(height: 12),
            Text(
              'image not available',
              style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
            ),
          ],
        ),
      );
}

String _extFor(String? mime, String path) {
  switch ((mime ?? '').toLowerCase()) {
    case 'image/png':
      return '.png';
    case 'image/webp':
      return '.webp';
    case 'image/gif':
      return '.gif';
    case 'image/jpeg':
    case 'image/jpg':
      return '.jpg';
  }
  final lower = path.toLowerCase();
  for (final e in ['.png', '.webp', '.gif', '.jpg', '.jpeg']) {
    if (lower.endsWith(e)) return e;
  }
  return '.jpg';
}
