import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';

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
                    _VoiceButton(
                      active: widget.recording,
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
    return Container(
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.12),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(22),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
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
