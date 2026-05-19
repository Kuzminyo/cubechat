import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';

/// Which media the right-hand record button currently captures.
/// A short tap on the button toggles between the two; long-press starts
/// recording in whichever mode is active.
enum RecordMode { audio, video }

class ChatInput extends StatefulWidget {
  const ChatInput({
    super.key,
    required this.hint,
    required this.sendTooltip,
    required this.onSend,
    this.onAttach,
    this.recordMode = RecordMode.audio,
    this.onRecordModeToggle,
    this.onRecordStart,
    this.onRecordStop,
    this.onRecordCancel,
    this.recording = false,
    this.recordElapsed = Duration.zero,
  });

  final String hint;
  final String sendTooltip;
  final ValueChanged<String> onSend;

  /// Tapped on the attachment (image) button. When null the button is
  /// hidden — caller decides whether image send is wired up.
  final VoidCallback? onAttach;

  /// Telegram-style single-button capture: short tap switches between
  /// audio (mic icon) and video (camera icon); long-press starts the
  /// recording in the active mode, release commits, drag-cancel discards.
  ///
  /// Wired by the caller through [onRecordModeToggle] / [onRecordStart] /
  /// [onRecordStop] / [onRecordCancel]. When the start handler is null,
  /// the button collapses (e.g. while the chat session isn't yet
  /// established).
  final RecordMode recordMode;
  final VoidCallback? onRecordModeToggle;
  final VoidCallback? onRecordStart;
  final VoidCallback? onRecordStop;
  final VoidCallback? onRecordCancel;

  /// True while a recording is in progress — flips the UI into
  /// "recording" mode (red dot + elapsed counter, hide the text input).
  final bool recording;
  final Duration recordElapsed;

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final _controller = TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.25),
            border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (widget.onAttach != null && !widget.recording) ...[
                    _AttachButton(onTap: widget.onAttach!),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: widget.recording
                        ? _RecordingIndicator(
                            elapsed: widget.recordElapsed,
                            mode: widget.recordMode,
                          )
                        : Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.10),
                              border: Border.all(
                                  color:
                                      Colors.white.withValues(alpha: 0.16)),
                              borderRadius: BorderRadius.circular(22),
                            ),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16),
                            child: TextField(
                              controller: _controller,
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
                                contentPadding: const EdgeInsets.symmetric(
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
                  const SizedBox(width: 8),
                  if (widget.onRecordStart != null &&
                      widget.onRecordStop != null &&
                      widget.onRecordCancel != null &&
                      !_hasText)
                    _RecordModeButton(
                      mode: widget.recordMode,
                      active: widget.recording,
                      onToggleMode: widget.onRecordModeToggle,
                      onStart: widget.onRecordStart!,
                      onStop: widget.onRecordStop!,
                      onCancel: widget.onRecordCancel!,
                    )
                  else
                    _SendButton(
                      enabled: _hasText,
                      tooltip: widget.sendTooltip,
                      onTap: _send,
                    ),
                ],
              ),
            ),
          ),
        ),
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
          color: Colors.white.withValues(alpha: 0.10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
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

/// Telegram-style single-button capture control. Short tap toggles between
/// the audio (mic) and video (circle) modes — the icon swaps to reflect
/// the next-tap action. Long-press starts recording in the active mode,
/// release commits via [onStop], drag-off cancels via [onCancel].
class _RecordModeButton extends StatelessWidget {
  const _RecordModeButton({
    required this.mode,
    required this.active,
    required this.onToggleMode,
    required this.onStart,
    required this.onStop,
    required this.onCancel,
  });

  final RecordMode mode;
  final bool active;
  final VoidCallback? onToggleMode;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Quick tap swaps mode (mic ↔ video). Suppressed while recording —
      // a stray tap mid-record would otherwise flip the icon under the
      // user's finger.
      onTap: active ? null : onToggleMode,
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
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          transitionBuilder: (child, anim) => ScaleTransition(
            scale: anim,
            child: FadeTransition(opacity: anim, child: child),
          ),
          child: Icon(
            mode == RecordMode.audio ? Icons.mic : Icons.videocam_outlined,
            key: ValueKey(mode),
            color: active ? Colors.white : AppColors.textOnGlass,
            size: 20,
          ),
        ),
      ),
    );
  }
}

class _RecordingIndicator extends StatelessWidget {
  const _RecordingIndicator({
    required this.elapsed,
    required this.mode,
  });

  final Duration elapsed;
  final RecordMode mode;

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.12),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(22),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          Icon(
            mode == RecordMode.audio ? Icons.mic : Icons.videocam,
            size: 14,
            color: AppColors.danger,
          ),
          const SizedBox(width: 8),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.danger,
            ),
          ),
          const SizedBox(width: 8),
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
            mode == RecordMode.audio ? 'release to send' : 'release to send',
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
  const _SendButton({required this.enabled, required this.tooltip, required this.onTap});

  final bool enabled;
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
              Icons.arrow_upward,
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
