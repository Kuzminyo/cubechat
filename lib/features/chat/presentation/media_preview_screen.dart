import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../l10n/app_localizations.dart';
import 'widgets/image_editor.dart';

/// What the preview returns: the (possibly edited) bytes and the caption.
class MediaPreviewResult {
  const MediaPreviewResult({required this.bytes, required this.caption});

  final List<Uint8List> bytes;

  /// Null when nothing was typed — an empty caption and no caption are the
  /// same thing, and only one of them should reach the wire.
  final String? caption;
}

/// Last stop before a photo goes out: see it full-size, write a line under it,
/// send.
///
/// This sits between the picker and the send because the previous flow gave no
/// chance to change your mind — a tap in the grid put the photo in the chat.
/// The caption field is the other half: it rides in the media manifest, so it
/// arrives with the picture as one bubble rather than as a second message.
///
/// The editor is one tap away rather than compulsory. Opening it for every
/// photo, as the old single-pick path did, made sending one picture a
/// three-screen errand.
class MediaPreviewScreen extends StatefulWidget {
  const MediaPreviewScreen({super.key, required this.items});

  /// Full-size bytes for each picked photo, in the order they were chosen.
  final List<Uint8List> items;

  @override
  State<MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends State<MediaPreviewScreen> {
  final _caption = TextEditingController();
  final _page = PageController();
  late final List<Uint8List> _bytes = [...widget.items];
  int _index = 0;

  @override
  void dispose() {
    _caption.dispose();
    _page.dispose();
    super.dispose();
  }

  Future<void> _edit() async {
    final edited = await openImageEditor(context, _bytes[_index]);
    if (edited == null || !mounted) return;
    setState(() => _bytes[_index] = edited);
  }

  void _send() {
    final text = _caption.text.trim();
    Navigator.of(context).pop(
      MediaPreviewResult(
        bytes: _bytes,
        caption: text.isEmpty ? null : text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final many = _bytes.length > 1;

    return Scaffold(
      backgroundColor: Colors.black,
      // The caption island positions itself off viewInsets.bottom, so the
      // Scaffold must not ALSO shrink the body for the keyboard — that counted
      // the keyboard twice and threw the caption bar most of the way up the
      // photo. Off is the right answer for a full-bleed preview anyway: the
      // image keeps its height instead of being squashed into the top half.
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: PageView.builder(
              controller: _page,
              itemCount: _bytes.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: Image.memory(_bytes[i], fit: BoxFit.contain),
                ),
              ),
            ),
          ),

          // Close, the counter, and the way into the editor.
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            left: 12,
            right: 12,
            child: Row(
              children: [
                _RoundAction(
                  icon: Icons.close,
                  onTap: () => Navigator.of(context).pop(),
                ),
                const Spacer(),
                if (many)
                  FloatingGlass(
                    borderRadius: 16,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    child: Text(
                      '${_index + 1}/${_bytes.length}',
                      style: TextStyle(
                        color: AppColors.textOnGlass,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                const Spacer(),
                _RoundAction(icon: Icons.brush_outlined, onTap: _edit),
              ],
            ),
          ),

          // Caption + send, as one island above the keyboard.
          Positioned(
            left: 10,
            right: 10,
            bottom: MediaQuery.viewInsetsOf(context).bottom +
                MediaQuery.paddingOf(context).bottom +
                10,
            child: FloatingGlass(
              borderRadius: 26,
              padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _caption,
                      maxLines: 4,
                      minLines: 1,
                      textCapitalization: TextCapitalization.sentences,
                      style: TextStyle(
                        color: AppColors.textOnGlass,
                        fontSize: 15,
                      ),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 12),
                        hintText: t.mediaCaptionHint,
                        hintStyle: TextStyle(
                          color: AppColors.textOnGlassDim,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _SendButton(onTap: _send, count: many ? _bytes.length : 0),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: Colors.white, size: 21),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.onTap, required this.count});

  final VoidCallback onTap;

  /// Badge showing how many photos go at once; 0 hides it.
  final int count;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          color: AppColors.brandPrimary,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: const Padding(
              padding: EdgeInsets.all(11),
              child: Icon(Icons.arrow_upward_rounded,
                  color: Color(0xFF06140D), size: 22),
            ),
          ),
        ),
        if (count > 0)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.bgTop,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: AppColors.brandPrimary, width: 1.2),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
