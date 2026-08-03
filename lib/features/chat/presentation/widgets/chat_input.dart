import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../l10n/app_localizations.dart';

/// The canonical smoked-glass texture for the message composer island.
/// Other chat chrome that must look identical should reuse this widget rather
/// than copying its gradient, border, blur and shadows.
class MessageIslandGlass extends StatelessWidget {
  const MessageIslandGlass({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = 26,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
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
          borderRadius: radius,
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
                borderRadius: radius,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.14),
                ),
              ),
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

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
    this.onRecordLock,
    this.recordLocked = false,
    this.recording = false,
    this.recordElapsed = Duration.zero,
    this.recordLevels = const <double>[],
    this.editingText,
    this.onEditCommit,
    this.onEditCancel,
    this.initialText,
    this.onChanged,
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

  /// Fired when the finger slides far enough up that the recording should
  /// continue without it. The caller flips [recordLocked].
  final VoidCallback? onRecordLock;

  /// True while a locked recording runs hands-free: the strip grows a Cancel
  /// button and the mic becomes Send.
  final bool recordLocked;

  /// True while a recording is in progress — flips the UI into
  /// "recording" mode (red dot + elapsed counter + live waveform).
  final bool recording;
  final Duration recordElapsed;

  /// Rolling input-loudness samples (0..1, newest last) for the waveform.
  final List<double> recordLevels;

  /// Persisted draft for this conversation. It is restored after inline edit
  /// mode as well, so editing an old message never destroys an unsent draft.
  final String? initialText;
  final ValueChanged<String>? onChanged;

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
  late final TextEditingController _controller;
  final _focus = FocusNode();
  bool _hasText = false;

  bool get _editing => widget.editingText != null;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText ?? '');
    _hasText = _controller.text.trim().isNotEmpty;
    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void didUpdateWidget(covariant ChatInput old) {
    super.didUpdateWidget(old);
    // Entering edit mode (or switching to a different message): load its text
    // and drop the caret at the end. Leaving edit mode restores the unsent
    // conversation draft instead of discarding it.
    if (widget.editingText != old.editingText) {
      if (widget.editingText != null) {
        _controller.text = widget.editingText!;
        _controller.selection =
            TextSelection.collapsed(offset: _controller.text.length);
        _focus.requestFocus();
      } else if (old.editingText != null) {
        _replaceText(widget.initialText ?? '');
      }
    } else if (!_editing && widget.initialText != old.initialText) {
      final next = widget.initialText ?? '';
      if (_controller.text != next) _replaceText(next);
    }
  }

  void _replaceText(String text) {
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
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
      widget.onChanged?.call('');
    }
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final showAttach =
        widget.onAttach != null && !widget.recording && !_editing;
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
        child: MessageIslandGlass(
          borderRadius: 26,
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
                            elapsed: widget.recordElapsed,
                            levels: widget.recordLevels,
                            locked: widget.recordLocked,
                            onCancel: widget.onRecordCancel,
                          )
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: TextField(
                              controller: _controller,
                              focusNode: _focus,
                              onChanged: _editing ? null : widget.onChanged,
                              minLines: 1,
                              maxLines: 5,
                              cursorColor: AppColors.brandPrimary,
                              textCapitalization: TextCapitalization.sentences,
                              style: TextStyle(
                                color: AppColors.textOnGlass,
                                fontSize: 14.5,
                              ),
                              onSubmitted: (_) => _send(),
                              textInputAction: TextInputAction.send,
                              decoration: InputDecoration(
                                isCollapsed: true,
                                contentPadding:
                                    const EdgeInsets.symmetric(vertical: 12),
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
                      locked: widget.recordLocked,
                      onStart: widget.onRecordStart!,
                      onStop: widget.onRecordStop!,
                      onCancel: widget.onRecordCancel!,
                      onLock: widget.onRecordLock ?? () {},
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

/// How far up the finger has to travel from the mic before the recording locks
/// and carries on without it, and how far left before it is thrown away.
///
/// Up is a bigger reach than left because locking is the recoverable outcome
/// and discarding is not: overshooting into "keep recording" costs a tap to
/// stop, overshooting into "discard" costs the whole message.
const double _voiceLockTravel = 56;
const double _voiceCancelTravel = 88;

/// Press-and-hold voice record button, with the two escapes a held button
/// needs: slide up to keep recording without holding, slide left to bin it.
///
/// Holding a button to talk is fine for five seconds and awful for sixty, and
/// until now releasing was the *only* outcome — there was no way to send a long
/// message without keeping a thumb planted, and no way to abandon one you had
/// started except by sending it and deleting it afterwards.
class _VoiceButton extends StatelessWidget {
  const _VoiceButton({
    required this.active,
    required this.locked,
    required this.onStart,
    required this.onStop,
    required this.onCancel,
    required this.onLock,
  });

  final bool active;

  /// True once the recording has been locked: the press has ended but the
  /// recording continues, and this button becomes "send".
  final bool locked;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onCancel;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    // Locked recording is driven by taps, not by a held press: the finger is
    // gone, so the same widget has to stop meaning "hold me" and start meaning
    // "send".
    if (locked) {
      return GestureDetector(
        onTap: onStop,
        child: _circle(context, icon: Icons.send_rounded, filled: true),
      );
    }
    return GestureDetector(
      onLongPressStart: (_) => onStart(),
      onLongPressEnd: (_) => onStop(),
      onLongPressCancel: onCancel,
      onLongPressMoveUpdate: (d) {
        if (!active) return;
        final offset = d.localOffsetFromOrigin;
        // Cancel wins a diagonal: a drag that reaches both thresholds was more
        // likely aimed at the bin than at the lock, and the safe reading of an
        // ambiguous gesture is the one that doesn't send.
        if (offset.dx <= -_voiceCancelTravel) {
          onCancel();
        } else if (offset.dy <= -_voiceLockTravel) {
          onLock();
        }
      },
      child: _circle(context, icon: Icons.mic, filled: active),
    );
  }

  Widget _circle(
    BuildContext context, {
    required IconData icon,
    required bool filled,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: filled
            ? AppColors.brandGradient
            : LinearGradient(
                colors: [
                  Colors.white.withValues(alpha: 0.18),
                  Colors.white.withValues(alpha: 0.10),
                ],
              ),
        boxShadow: filled
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
        icon,
        color: filled ? Colors.white : AppColors.textOnGlass,
        size: 20,
      ),
    );
  }
}

/// Telegram-style recording strip: a pulsing red dot, the elapsed timer, and a
/// live waveform that grows from the right as you speak.
class _RecordingIndicator extends StatefulWidget {
  const _RecordingIndicator({
    required this.elapsed,
    required this.levels,
    this.locked = false,
    this.onCancel,
  });

  final Duration elapsed;
  final List<double> levels;

  /// Locked recordings have no finger on the button, so the way out has to be
  /// on screen: while held, sliding is the way out and the strip says so.
  final bool locked;
  final VoidCallback? onCancel;

  @override
  State<_RecordingIndicator> createState() => _RecordingIndicatorState();
}

class _RecordingIndicatorState extends State<_RecordingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      child: Row(
        children: [
          FadeTransition(
            opacity: Tween<double>(begin: 1, end: 0.25).animate(_pulse),
            child: Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.danger,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _fmt(widget.elapsed),
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 14,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 26,
              child: CustomPaint(
                painter: _WaveformPainter(widget.levels),
                size: Size.infinite,
              ),
            ),
          ),
          if (widget.locked && widget.onCancel != null)
            TextButton(
              onPressed: widget.onCancel,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                MaterialLocalizations.of(context).cancelButtonLabel,
                style: const TextStyle(
                  color: AppColors.danger,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            // While the finger is down, the escapes are gestures — say which.
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(
                Icons.keyboard_arrow_up_rounded,
                size: 18,
                color: AppColors.textOnGlassFaint,
              ),
            ),
        ],
      ),
    );
  }
}

/// Draws the loudness samples as vertical rounded bars, anchored to the right
/// so the newest sample is always at the leading edge and older ones scroll
/// away. Older bars fade so the motion reads as "flowing".
class _WaveformPainter extends CustomPainter {
  _WaveformPainter(this.levels);

  final List<double> levels;

  static const double _barW = 3;
  static const double _gap = 2.5;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    final maxBars = (size.width / (_barW + _gap)).floor();
    if (maxBars <= 0) return;
    final show = levels.length > maxBars
        ? levels.sublist(levels.length - maxBars)
        : levels;

    final mid = size.height / 2;
    // Right-anchored: last bar sits at the right edge.
    var x = size.width - show.length * (_barW + _gap) + _gap / 2;
    for (var i = 0; i < show.length; i++) {
      final h = (show[i].clamp(0.06, 1.0)) * size.height;
      final fade = 0.35 + 0.65 * (i / show.length); // older = dimmer
      final paint = Paint()
        ..color = AppColors.brandPrimary.withValues(alpha: fade)
        ..style = PaintingStyle.fill;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, mid - h / 2, _barW, h),
        const Radius.circular(2),
      );
      canvas.drawRRect(rect, paint);
      x += _barW + _gap;
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) => old.levels != levels;
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
        onTapDown:
            widget.enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp:
            widget.enabled ? (_) => setState(() => _pressed = false) : null,
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
