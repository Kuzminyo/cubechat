import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/colors.dart';
import '../util/platform_info.dart';

/// What a toast is telling you, which decides its accent — not its surface.
///
/// The pane stays smoked glass in every case, the same as every other floating
/// element in the app. Only the icon and the hairline pick up colour, so a
/// failure reads as urgent without a bright slab of red arriving over the
/// conversation.
enum ToastTone { neutral, success, danger }

/// Brief, self-dismissing confirmation shown over the app — "Copied",
/// "Forwarded to …", "Couldn't connect".
///
/// Deliberately not a [SnackBar]. The app had eighteen of those and no
/// [SnackBarTheme], so every one of them arrived as a light Material slab in
/// the middle of a dark glass interface, shoving the composer around as it
/// came and went. This rides an [OverlayEntry] instead: it floats above
/// everything, disturbs no layout, and is built from the same recipe as the
/// nav bar and the chat bubbles.
class _GlassToastHost {
  static OverlayEntry? _current;
  static Timer? _dismiss;

  static void show(
    BuildContext context,
    String message, {
    required ToastTone tone,
    IconData? icon,
    Duration duration = const Duration(milliseconds: 1900),
  }) {
    // Root overlay, not the nearest one: a confirmation often accompanies the
    // dismissal of the sheet or dialog that triggered it, and an entry in that
    // route's own overlay would be torn down with it. This is also why callers
    // don't need to capture a ScaffoldMessenger before an await the way the
    // SnackBars did.
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    // A second toast replaces the first rather than stacking on top of it —
    // two panes over each other is exactly the mess this is replacing.
    _removeCurrent();

    final controller = _ToastController();
    final entry = OverlayEntry(
      builder: (_) => _GlassToast(
        message: message,
        tone: tone,
        icon: icon,
        controller: controller,
      ),
    );
    _current = entry;
    overlay.insert(entry);

    unawaited(HapticFeedback.selectionClick());

    _dismiss = Timer(duration, () async {
      // Play the exit before tearing the entry down, so it fades out rather
      // than blinking away.
      await controller.reverse();
      if (_current == entry) _removeCurrent();
    });
  }

  static void _removeCurrent() {
    _dismiss?.cancel();
    _dismiss = null;
    _current?.remove();
    _current = null;
  }
}

/// Lets the host drive the exit animation of a widget it does not own.
class _ToastController {
  Future<void> Function()? _reverse;
  Future<void> reverse() async => _reverse?.call();
}

class _GlassToast extends StatefulWidget {
  const _GlassToast({
    required this.message,
    required this.tone,
    required this.icon,
    required this.controller,
  });

  final String message;
  final ToastTone tone;
  final IconData? icon;
  final _ToastController controller;

  @override
  State<_GlassToast> createState() => _GlassToastState();
}

class _GlassToastState extends State<_GlassToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 180),
  );

  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

  /// Rises into place rather than appearing — the same gesture the message
  /// bubbles make when they arrive.
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.6),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  late final Animation<double> _scale = Tween<double>(
    begin: 0.94,
    end: 1,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutBack));

  @override
  void initState() {
    super.initState();
    widget.controller._reverse = () async {
      if (mounted) await _c.reverse();
    };
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Color get _accent => switch (widget.tone) {
        ToastTone.neutral => AppColors.textOnGlass,
        ToastTone.success => AppColors.brandPrimary,
        ToastTone.danger => AppColors.danger,
      };

  IconData? get _icon =>
      widget.icon ??
      switch (widget.tone) {
        ToastTone.neutral => null,
        ToastTone.success => Icons.check_rounded,
        ToastTone.danger => Icons.error_outline_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(22);
    final icon = _icon;

    return Positioned(
      left: 16,
      right: 16,
      // Clear of the floating composer, so a confirmation never lands on the
      // control that produced it.
      bottom: MediaQuery.of(context).viewInsets.bottom +
          MediaQuery.of(context).padding.bottom +
          96,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _fade,
          child: SlideTransition(
            position: _slide,
            child: ScaleTransition(
              scale: _scale,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.55),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                        spreadRadius: -6,
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: radius,
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                      child: Container(
                        padding: EdgeInsets.fromLTRB(
                          icon == null ? 20 : 16,
                          12,
                          20,
                          12,
                        ),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(alpha: 0.07),
                              Colors.black.withValues(alpha: 0.62),
                            ],
                          ),
                          borderRadius: radius,
                          border: Border.all(
                            color: widget.tone == ToastTone.neutral
                                ? Colors.white.withValues(alpha: 0.16)
                                : _accent.withValues(alpha: 0.45),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (icon != null) ...[
                              Icon(icon, size: 18, color: _accent),
                              const SizedBox(width: 10),
                            ],
                            Flexible(
                              child: Text(
                                widget.message,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: AppColors.textOnGlass,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
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

/// Confirm that something was put on the clipboard.
///
/// **No-op on Android.** Since Android 13 the system pops its own "Copied to
/// clipboard." toast for every clipboard write, and ours arrived on top of it —
/// two overlapping confirmations for one action, which is what this whole pass
/// is fixing. The system owns this particular feedback there; we only speak up
/// on platforms where nothing else does.
///
/// The cost is Android 12 and below, which shows no system toast and so now
/// gets no confirmation. That is the better trade: a shrinking slice of
/// devices loses a nicety, where every current Android device was seeing a
/// visible duplicate.
///
/// Every clipboard action routes through here rather than each call site
/// re-deciding, so the rule can't drift apart between screens.
void showCopiedToast(BuildContext context, String message) {
  if (PlatformInfo.isAndroid) return;
  showGlassToast(
    context,
    message,
    icon: Icons.copy_outlined,
    tone: ToastTone.success,
  );
}

/// Show a brief confirmation over the app. See [_GlassToastHost].
void showGlassToast(
  BuildContext context,
  String message, {
  ToastTone tone = ToastTone.neutral,
  IconData? icon,
  Duration duration = const Duration(milliseconds: 1900),
}) =>
    _GlassToastHost.show(
      context,
      message,
      tone: tone,
      icon: icon,
      duration: duration,
    );
