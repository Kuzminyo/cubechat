import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../l10n/app_localizations.dart';

class ChatInput extends StatefulWidget {
  const ChatInput({
    super.key,
    required this.hint,
    required this.sendTooltip,
    required this.onSend,
    this.onAttach,
    this.onRecordStart,
    this.onRecordStop,
    this.onRecordCancel,
    this.recording = false,
    this.recordElapsed = Duration.zero,
    this.editingText,
    this.onEditCommit,
    this.onEditCancel,
  });

  final String hint;
  final String sendTooltip;
  final ValueChanged<String> onSend;

  /// Tapped on the attachment (image) button. When null the button is
  /// hidden — caller decides whether image send is wired up.
  final VoidCallback? onAttach;

  /// Press-and-hold voice recording. When all three are non-null the mic
  /// button appears next to send; long-press drives onRecordStart, release
  /// commits via onRecordStop, drag-cancel via onRecordCancel.
  final VoidCallback? onRecordStart;
  final VoidCallback? onRecordStop;
  final VoidCallback? onRecordCancel;

  /// True while a recording is in progress — flips the UI into
  /// "recording" mode (red dot + elapsed counter, hide the text input).
  final bool recording;
  final Duration recordElapsed;

  /// Non-null puts the input in edit mode: the field is prefilled with this
  /// text, an "editing" banner shows, and the send button commits via
  /// [onEditCommit] instead of [onSend].
  final String? editingText;
  final ValueChanged<String>? onEditCommit;
  final VoidCallback? onEditCancel;

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _hasText = false;

  bool get _editing => widget.editingText != null;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void didUpdateWidget(covariant ChatInput old) {
    super.didUpdateWidget(old);
    // Entering edit mode (or switching to a different message): load its text
    // and drop the caret at the end, ready to change. Leaving edit mode clears
    // the draft the edit left behind.
    if (widget.editingText != old.editingText) {
      if (widget.editingText != null) {
        _controller.text = widget.editingText!;
        _controller.selection =
            TextSelection.collapsed(offset: _controller.text.length);
        _focus.requestFocus();
      } else if (old.editingText != null) {
        _controller.clear();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (_editing) {
      widget.onEditCommit?.call(text);
    } else {
      widget.onSend(text);
    }
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final showAttach = widget.onAttach != null && !widget.recording && !_editing;
    final showVoice = widget.onRecordStart != null &&
        widget.onRecordStop != null &&
        widget.onRecordCancel != null &&
        !_hasText &&
        !_editing;

    return SafeArea(
      top: false,
      // Margins on every side: the capsule floats, with the aurora showing
      // through around it. No full-width plate, no welded top border.
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 10,
                offset: const Offset(0, 4),
                spreadRadius: -4,
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 22,
                offset: const Offset(0, 10),
                spreadRadius: -12,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.07),
                      Colors.black.withValues(alpha: 0.48),
                      Colors.black.withValues(alpha: 0.60),
                    ],
                    stops: const [0, 0.35, 1],
                  ),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_editing)
                        _EditBanner(
                          text: widget.editingText!,
                          onCancel: widget.onEditCancel,
                        ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (showAttach) ...[
                            _AttachButton(onTap: widget.onAttach!),
                            const SizedBox(width: 6),
                          ],
                          Expanded(
                            child: widget.recording
                                ? _RecordingIndicator(
                                    elapsed: widget.recordElapsed)
                                : Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    child: TextField(
                                      controller: _controller,
                                      focusNode: _focus,
                                      minLines: 1,
                                      maxLines: 5,
                                      cursorColor: AppColors.brandPrimary,
                                      style: TextStyle(
                                        color: AppColors.textOnGlass,
                                        fontSize: 14.5,
                                      ),
                                      onSubmitted: (_) => _send(),
                                      textInputAction: TextInputAction.send,
                                      decoration: InputDecoration(
                                        isCollapsed: true,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                                vertical: 12),
                                        border: InputBorder.none,
                                        hintText: widget.hint,
                                        hintStyle: TextStyle(
                                          color: AppColors.textOnGlassFaint,
                                          fontSize: 14.5,
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                          const SizedBox(width: 6),
                          if (showVoice)
                            _VoiceButton(
                              active: widget.recording,
                              onStart: widget.onRecordStart!,
                              onStop: widget.onRecordStop!,
                              onCancel: widget.onRecordCancel!,
                            )
                          else
                            _SendButton(
                              enabled: _hasText,
                              isEdit: _editing,
                              tooltip: widget.sendTooltip,
                              onTap: _send,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The small "editing" strip Telegram shows above the field: an accent bar, the
/// label, the message being edited, and a close button to bail out.
class _EditBanner extends StatelessWidget {
  const _EditBanner({required this.text, required this.onCancel});

  final String text;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 2, 4),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.brandPrimary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Icon(Icons.edit_outlined, size: 16, color: AppColors.brandPrimary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.chatEditTitle,
                  style: TextStyle(
                    color: AppColors.brandPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: onCancel,
            icon: Icon(Icons.close, size: 18, color: AppColors.textOnGlassDim),
          ),
        ],
      ),
    );
  }
}

class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.08),
        ),
        child: Icon(
          Icons.image_outlined,
          color: AppColors.textOnGlass,
          size: 20,
        ),
      ),
    );
  }
}

/// Press-and-hold voice record button. Plain mic icon; flips into a red
/// "recording" state while held.
class _VoiceButton extends StatelessWidget {
  const _VoiceButton({
    required this.active,
    required this.onStart,
    required this.onStop,
    required this.onCancel,
  });

  final bool active;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) => onStart(),
      onLongPressEnd: (_) => onStop(),
      onLongPressCancel: onCancel,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: active
              ? LinearGradient(
                  colors: [
                    AppColors.danger.withValues(alpha: 0.95),
                    AppColors.danger.withValues(alpha: 0.7),
                  ],
                )
              : LinearGradient(
                  colors: [
                    Colors.white.withValues(alpha: 0.18),
                    Colors.white.withValues(alpha: 0.10),
                  ],
                ),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: AppColors.danger.withValues(alpha: 0.45),
                    blurRadius: 16,
                    spreadRadius: -2,
                  ),
                ]
              : null,
        ),
        child: Icon(
          Icons.mic,
          color: active ? Colors.white : AppColors.textOnGlass,
          size: 20,
        ),
      ),
    );
  }
}

class _RecordingIndicator extends StatelessWidget {
  const _RecordingIndicator({required this.elapsed});

  final Duration elapsed;

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.danger,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _fmt(elapsed),
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 14,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const Spacer(),
          Text(
            'release to send',
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _SendButton extends StatefulWidget {
  const _SendButton({
    required this.enabled,
    required this.tooltip,
    required this.onTap,
    this.isEdit = false,
  });

  final bool enabled;
  final bool isEdit;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: GestureDetector(
        onTapDown: widget.enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: widget.enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedScale(
          scale: _pressed ? 0.90 : (widget.enabled ? 1.0 : 0.88),
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: widget.enabled
                  ? AppColors.brandGradient
                  : LinearGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0.18),
                        Colors.white.withValues(alpha: 0.10),
                      ],
                    ),
              boxShadow: widget.enabled
                  ? [
                      BoxShadow(
                        color: AppColors.brandPrimary.withValues(alpha: 0.45),
                        blurRadius: 16,
                        spreadRadius: -2,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              widget.isEdit ? Icons.check : Icons.arrow_upward,
              color: widget.enabled
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.55),
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}
