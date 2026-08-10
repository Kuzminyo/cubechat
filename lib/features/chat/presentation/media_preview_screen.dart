import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../l10n/app_localizations.dart';
import 'widgets/image_editor.dart';

/// What the preview returns: the (possibly edited) bytes and the caption.
class MediaPreviewResult {
  const MediaPreviewResult({
    required this.bytes,
    required this.caption,
    this.asFile = false,
    this.viewOnce = false,
  });

  final List<Uint8List> bytes;

  /// Null when nothing was typed — an empty caption and no caption are the
  /// same thing, and only one of them should reach the wire.
  final String? caption;

  /// Send the originals through the file path instead of the photo path.
  ///
  /// The photo path exists to fit a picture through Bluetooth: it downscales
  /// and re-encodes, which is the right trade for a snapshot and the wrong one
  /// for a document photographed to be read, or for anything that has to arrive
  /// as it left. Telegram calls this sending without compression; here it also
  /// means [bytes] is ignored and the caller reaches for the asset's own file.
  final bool asFile;

  /// Send it as a photo that disappears from both sides once opened.
  final bool viewOnce;
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
  const MediaPreviewScreen({
    super.key,
    required this.items,
    this.allowOriginal = true,
    this.allowViewOnce = false,
    this.initialCaption,
  });

  /// Full-size bytes for each picked photo, in the order they were chosen.
  final List<Uint8List> items;

  /// False in a channel: "send original" goes out through the file transport,
  /// which a room does not carry. The toggle is hidden rather than shown and
  /// refused.
  final bool allowOriginal;

  /// False in a channel and in saved notes. A room has no single recipient
  /// whose looking could mean "everyone has seen it", and a note to yourself
  /// has nobody to hide it from.
  final bool allowViewOnce;

  /// Text composed in the gallery sheet before this full-size preview.
  final String? initialCaption;

  @override
  State<MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends State<MediaPreviewScreen> {
  late final TextEditingController _caption;
  final _page = PageController();
  late final List<Uint8List> _bytes = [...widget.items];
  int _index = 0;

  /// Send the file as it sits on disk rather than a re-encoded copy.
  bool _asFile = false;

  /// Send it as a photo that burns after one look.
  bool _viewOnce = false;

  @override
  void initState() {
    super.initState();
    _caption = TextEditingController(text: widget.initialCaption);
  }

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
        asFile: _asFile,
        viewOnce: _viewOnce,
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
                // Sending the original goes down the file path, which has no
                // view-once flag and no viewer to burn it in — so the two are
                // mutually exclusive rather than quietly contradictory.
                if (widget.allowViewOnce && !_asFile) ...[
                  _OriginalToggle(
                    label: t.viewOnceSendLabel,
                    active: _viewOnce,
                    onTap: () => setState(() => _viewOnce = !_viewOnce),
                  ),
                  const SizedBox(width: 8),
                ],
                if (widget.allowOriginal && !_viewOnce)
                  _OriginalToggle(
                    label: t.mediaSendOriginal,
                    active: _asFile,
                    onTap: () => setState(() => _asFile = !_asFile),
                  ),
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
              padding: EdgeInsets.fromLTRB(_asFile ? 16 : 6, 6, 6, 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // The brush lives down here with the caption and the send
                  // button, because those are the three things you do to a
                  // photo before it leaves. Up in the top bar it sat among
                  // controls that change what the *recipient* gets — a
                  // different question entirely — with the photo itself
                  // between them.
                  //
                  // Editing a photo you are about to send untouched is a
                  // contradiction (the edit would be the one thing that got
                  // re-encoded), so it stands down while "original" is on.
                  if (!_asFile) ...[
                    _CaptionAction(icon: Icons.brush_outlined, onTap: _edit),
                    const SizedBox(width: 4),
                  ],
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

/// "Send as a file" — a labelled pill rather than another round icon.
///
/// It is the one control up here that changes what the *recipient* gets rather
/// than what this screen shows, and an unlabelled glyph for that is a guess. It
/// also has a state, which a round icon has nowhere to put.
class _OriginalToggle extends StatelessWidget {
  const _OriginalToggle({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active
          ? AppColors.brandPrimary.withValues(alpha: 0.9)
          : Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                active
                    ? Icons.insert_drive_file_rounded
                    : Icons.insert_drive_file_outlined,
                size: 17,
                color: active ? AppColors.bgDeep : Colors.white,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: active ? AppColors.bgDeep : Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An icon button sized to sit inside the caption island.
///
/// Not a [_RoundAction]: that one is a black disc for punching through a
/// full-bleed photo, and inside the island it would read as a second surface
/// stacked on the glass. Here the glyph alone is the control, in the brand
/// colour, the way the composer's own icons are.
class _CaptionAction extends StatelessWidget {
  const _CaptionAction({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: AppColors.brandPrimary, size: 23),
        ),
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
            child: Padding(
              padding: const EdgeInsets.all(11),
              // Ink *on* the brand colour, so it has to be the palette's own
              // dark — a green arrow on a pink send button was the frozen
              // emerald showing through again.
              child: Icon(Icons.arrow_upward_rounded,
                  color: AppColors.bgDeep, size: 22),
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
