import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../core/theme/glass.dart';
import 'emoji_sticker_panel.dart';

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
            filter: AppBlur.pane,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppColors.glass(0.07),
                    AppColors.pane(0.48),
                    AppColors.pane(0.60),
                  ],
                  stops: const [0, 0.35, 1],
                ),
                borderRadius: radius,
                border: Border.all(
                  color: AppColors.glass(0.14),
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
    this.onSticker,
    this.onCreateSticker,
    this.openStickerPanel,
  });

  /// Bumped by the screen around this one to say "open the panel on stickers".
  final ValueListenable<int>? openStickerPanel;

  final String hint;
  final String sendTooltip;
  final ValueChanged<String> onSend;

  /// Tapped on the attachment button. When null the button is hidden.
  final VoidCallback? onAttach;

  /// A sticker was chosen in the smiley panel: file path plus its emoji name.
  final void Function(String path, String? emoji)? onSticker;

  /// Tapped "make a sticker" in the panel.
  final Future<bool> Function()? onCreateSticker;

  final VoidCallback? onRecordStart;
  final VoidCallback? onRecordStop;
  final VoidCallback? onRecordCancel;
  final VoidCallback? onRecordLock;
  final bool recordLocked;
  final bool recording;
  final Duration recordElapsed;
  final List<double> recordLevels;
  final String? initialText;
  final ValueChanged<String>? onChanged;
  final String? editingText;
  final ValueChanged<String>? onEditCommit;
  final VoidCallback? onEditCancel;

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> with WidgetsBindingObserver {
  late final TextEditingController _controller;
  final _focus = FocusNode();
  bool _hasText = false;
  bool _panelOpen = false;
  bool _panelOnStickers = false;
  bool _closingPanel = false;

  /// Fallback for a keyboard that never arrives — see [_armKeyboardWatchdog].
  Timer? _keyboardWatchdog;

  bool get _editing => widget.editingText != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.openStickerPanel?.addListener(_openStickersFromOutside);
    _focus.addListener(_closePanelWhenFieldFocused);
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
    if (old.openStickerPanel != widget.openStickerPanel) {
      old.openStickerPanel?.removeListener(_openStickersFromOutside);
      widget.openStickerPanel?.addListener(_openStickersFromOutside);
    }
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
      if (_controller.text != next && !_focus.hasFocus) _replaceText(next);
    }
  }

  void _replaceText(String text) {
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
  }

  void closePanel() {
    if (!_panelOpen || _closingPanel) return;
    setState(() => _closingPanel = true);
    Future<void>.delayed(AnimatedEmojiStickerPanel.motion, () {
      if (!mounted) return;
      setState(() {
        _panelOpen = false;
        _closingPanel = false;
      });
    });
  }

  void _openStickersFromOutside() {
    if (mounted && widget.onSticker != null) _togglePanel(stickers: true);
  }

  @override
  void dispose() {
    _keyboardWatchdog?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.openStickerPanel?.removeListener(_openStickersFromOutside);
    _focus.removeListener(_closePanelWhenFieldFocused);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Drop the panel once the keyboard has taken most of the slot they share.
  ///
  /// Half, not "any of it" and not "all of it". Any of it fires on the first
  /// frame of the keyboard's rise, which is the hole this exists to avoid; all
  /// of it never fires when the live keyboard is shorter than the tallest one
  /// [KeyboardHeight] has seen (one with a suggestion strip, say) — and the
  /// panel then stays open *under* the keyboard, which is the bug that started
  /// this. Halfway is reached by every keyboard and by nothing else.
  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_panelOpen) return;
      final view = View.maybeOf(context);
      if (view == null) return;
      // Physical pixels on a FlutterView; the panel is measured in logical ones.
      final inset = view.viewInsets.bottom / view.devicePixelRatio;
      if (inset > KeyboardHeight.value / 2) _closePanelImmediately();
    });
  }

  /// The keyboard was asked for but never came — no soft keyboard on this
  /// device, focus refused, or a hardware keyboard attached. The panel would
  /// otherwise sit there forever waiting for an inset that is not coming.
  void _armKeyboardWatchdog() {
    _keyboardWatchdog?.cancel();
    _keyboardWatchdog = Timer(const Duration(milliseconds: 450), () {
      if (mounted) _closePanelImmediately();
    });
  }

  void _closePanelWhenFieldFocused() {
    // Tapping the field is the other way to ask for the keyboard, and it gets
    // the same swap: the panel holds its space until the keyboard is halfway
    // up rather than blinking out under the finger.
    if (_focus.hasFocus && _panelOpen) _armKeyboardWatchdog();
  }

  void _closePanelImmediately() {
    _keyboardWatchdog?.cancel();
    _keyboardWatchdog = null;
    if (!_panelOpen && !_closingPanel) return;
    setState(() {
      _panelOpen = false;
      _closingPanel = false;
    });
  }

  void _insertEmoji(String emoji) {
    final text = _controller.text;
    final selection = _controller.selection;
    final start = selection.start < 0 ? text.length : selection.start;
    final end = selection.end < 0 ? text.length : selection.end;
    final next = text.replaceRange(start, end, emoji);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
    if (!_editing) widget.onChanged?.call(next);
  }

  void _togglePanel({bool stickers = false}) {
    if (_panelOpen && !stickers) {
      // The panel stays up and shrinks as the keyboard rises into its place —
      // see [didChangeMetrics] for what finally takes it out of the tree.
      _focus.requestFocus();
      _armKeyboardWatchdog();
      return;
    }
    _keyboardWatchdog?.cancel();
    _keyboardWatchdog = null;
    _focus.unfocus();
    setState(() {
      _panelOnStickers = stickers;
      _closingPanel = false;
      _panelOpen = true;
    });
  }

  Future<void> _createStickerThenReopen() async {
    final made = await widget.onCreateSticker!();
    if (!mounted || !made) return;
    _togglePanel(stickers: true);
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
    KeyboardHeight.observe(context);
    final showAttach =
        widget.onAttach != null && !widget.recording && !_editing;
    final showEmoji = !widget.recording;
    final showVoice = widget.onRecordStart != null &&
        widget.onRecordStop != null &&
        widget.onRecordCancel != null &&
        !_hasText &&
        !_editing;

    return PopScope<void>(
      canPop: !_panelOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) closePanel();
      },
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _capsule(
              showEmoji: showEmoji,
              showAttach: showAttach,
              showVoice: showVoice,
            ),
            if (_panelOpen)
              AnimatedEmojiStickerPanel(
                visible: !_closingPanel,
                startOnStickers: _panelOnStickers,
                onEmoji: _insertEmoji,
                onSticker: widget.onSticker,
                onCreateSticker: widget.onCreateSticker == null
                    ? null
                    : () => unawaited(_createStickerThenReopen()),
              ),
          ],
        ),
      ),
    );
  }

  Widget _capsule({
    required bool showEmoji,
    required bool showAttach,
    required bool showVoice,
  }) {
    return Padding(
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
                if (showEmoji) ...[
                  _RoundIconButton(
                    icon: _panelOpen
                        ? Icons.keyboard_alt_outlined
                        : Icons.emoji_emotions_outlined,
                    onTap: _togglePanel,
                  ),
                  const SizedBox(width: 4),
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
                            keyboardType: TextInputType.multiline,
                            autocorrect: true,
                            enableSuggestions: true,
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
                if (showAttach) ...[
                  const SizedBox(width: 2),
                  _RoundIconButton(
                    icon: Icons.attach_file_rounded,
                    onTap: widget.onAttach!,
                  ),
                ],
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

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onTap});

  final IconData icon;
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
          color: AppColors.glass(0.08),
        ),
        child: Icon(icon, color: AppColors.textOnGlass, size: 20),
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

/// How long the mic has to be held before recording arms.
///
/// Flutter's stock long press is 500 ms, and a press-to-talk button that
/// ignores the first half-second does not feel like it is listening — you hold,
/// nothing happens, you hold harder. Telegram arms as good as immediately.
///
/// Not zero, because the mic still has to be a *held* gesture: at 0 a stray tap
/// while scrolling the composer would start recording, and the button has to
/// lose the arena to the scroll gesture it sits inside. 90 ms is under the
/// threshold where a delay is felt at all and still long enough to be a hold.
const Duration _voiceArmDelay = Duration(milliseconds: 90);

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
    // Raw recogniser rather than [GestureDetector] purely so the hold can be
    // armed at [_voiceArmDelay] instead of the stock half second — everything
    // else is the same long-press gesture.
    return RawGestureDetector(
      gestures: {
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(duration: _voiceArmDelay),
          (recognizer) {
            recognizer
              ..onLongPressStart = ((_) => onStart())
              ..onLongPressEnd = ((_) => onStop())
              ..onLongPressCancel = onCancel
              ..onLongPressMoveUpdate = (LongPressMoveUpdateDetails d) {
                if (!active) return;
                final offset = d.localOffsetFromOrigin;
                // Cancel wins a diagonal: a drag that reaches both thresholds
                // was more likely aimed at the bin than at the lock, and the
                // safe reading of an ambiguous gesture is the one that doesn't
                // send.
                if (offset.dx <= -_voiceCancelTravel) {
                  onCancel();
                } else if (offset.dy <= -_voiceLockTravel) {
                  onLock();
                }
              };
          },
        ),
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
                  AppColors.glass(0.18),
                  AppColors.glass(0.10),
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
                        AppColors.glass(0.18),
                        AppColors.glass(0.10),
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
              color: widget.enabled ? Colors.white : AppColors.ink(0.55),
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}
