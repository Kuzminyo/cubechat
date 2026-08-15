import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../../../core/routing/page_transitions.dart';
import '../../../../core/theme/colors.dart';
import '../../../../l10n/app_localizations.dart';

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
  bool _cutObject = true;
  bool _busy = false;

  Future<void> _confirm() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = _cutObject
          ? await compute(_makeStickerCutout, widget.source)
          : widget.source;
      if (!mounted) return;
      Navigator.of(context).pop(bytes);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cutLabel = _stickerText(
      context,
      uk: 'Вирізати об’єкт',
      en: 'Cut out object',
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 74,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    iconSize: 34,
                    color: Colors.white,
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t.stickerCreate,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 18),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth,
                        maxHeight: constraints.maxHeight,
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(
                            child: Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(22, 20, 22, 28),
                              child: Image.memory(
                                widget.source,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(22, 20, 22, 28),
                              child: CustomPaint(
                                painter: _StickerCutoutPainter(
                                  active: _cutObject,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 8,
                            child: _CutObjectButton(
                              label: cutLabel,
                              active: _cutObject,
                              onTap: _busy
                                  ? null
                                  : () =>
                                      setState(() => _cutObject = !_cutObject),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 22, 28, 20),
              child: Row(
                children: [
                  Expanded(
                    child: _StickerToolsBar(
                      activeCutout: _cutObject,
                      onCutout: _busy
                          ? null
                          : () => setState(() => _cutObject = !_cutObject),
                    ),
                  ),
                  const SizedBox(width: 28),
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

class _CutObjectButton extends StatelessWidget {
  const _CutObjectButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFF4C3C2F).withValues(alpha: 0.92)
                : const Color(0xFF202020).withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.38),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_fix_high_rounded,
                color: Colors.white,
                size: 27,
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StickerToolsBar extends StatelessWidget {
  const _StickerToolsBar({required this.activeCutout, required this.onCutout});

  final bool activeCutout;
  final VoidCallback? onCutout;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 76,
      decoration: BoxDecoration(
        color: const Color(0xFF1D1D1D),
        borderRadius: BorderRadius.circular(38),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ToolButton(
            icon: Icons.crop_rotate_rounded,
            active: !activeCutout,
            onTap: onCutout,
          ),
          _ToolButton(
            icon: Icons.brush_rounded,
            active: activeCutout,
            onTap: onCutout,
          ),
          _ToolButton(
            icon: Icons.tune_rounded,
            active: false,
            onTap: onCutout,
          ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.icon, required this.active, this.onTap});

  final IconData icon;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon),
      iconSize: 34,
      color: active ? AppColors.brandPrimary : Colors.white,
      splashRadius: 32,
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
      width: 82,
      height: 76,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF151515),
          borderRadius: BorderRadius.circular(38),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Material(
            color: const Color(0xFF2EA7FF),
            borderRadius: BorderRadius.circular(32),
            child: InkWell(
              onTap: busy ? null : onTap,
              borderRadius: BorderRadius.circular(32),
              child: Center(
                child: busy
                    ? const SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Icon(
                        Icons.check_rounded,
                        color: Colors.white,
                        size: 42,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StickerCutoutPainter extends CustomPainter {
  const _StickerCutoutPainter({required this.active});

  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      size.width * 0.035,
      size.height * 0.16,
      size.width * 0.93,
      size.height * 0.68,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(46));
    final scrim = Paint()
      ..color = Colors.black.withValues(alpha: active ? 0.18 : 0.30);
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(rrect);
    canvas.drawPath(outside, scrim);
    if (!active) return;

    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.68)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round;
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      const dash = 13.0;
      const gap = 13.0;
      while (distance < metric.length) {
        canvas.drawPath(
          metric.extractPath(
              distance, math.min(distance + dash, metric.length)),
          paint,
        );
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_StickerCutoutPainter oldDelegate) =>
      oldDelegate.active != active;
}

Uint8List _makeStickerCutout(Uint8List source) {
  final decoded = img.decodeImage(source);
  if (decoded == null) return source;
  final baked = img.bakeOrientation(decoded);
  final x = (baked.width * 0.035).round().clamp(0, baked.width - 1);
  final y = (baked.height * 0.16).round().clamp(0, baked.height - 1);
  final width = (baked.width * 0.93).round().clamp(1, baked.width - x);
  final height = (baked.height * 0.68).round().clamp(1, baked.height - y);
  final cropped = img.copyCrop(baked, x: x, y: y, width: width, height: height);
  final out =
      img.Image(width: cropped.width, height: cropped.height, numChannels: 4);
  final radius = math.min(cropped.width, cropped.height) * 0.13;
  for (var py = 0; py < cropped.height; py++) {
    for (var px = 0; px < cropped.width; px++) {
      final p = cropped.getPixel(px, py);
      final alpha =
          _insideRoundedRect(px, py, cropped.width, cropped.height, radius)
              ? p.a
              : 0;
      out.setPixelRgba(px, py, p.r, p.g, p.b, alpha);
    }
  }
  return Uint8List.fromList(img.encodePng(out));
}

bool _insideRoundedRect(int x, int y, int width, int height, double radius) {
  final left = radius;
  final right = width - radius - 1;
  final top = radius;
  final bottom = height - radius - 1;
  final dx = x < left
      ? left - x
      : x > right
          ? x - right
          : 0.0;
  final dy = y < top
      ? top - y
      : y > bottom
          ? y - bottom
          : 0.0;
  return dx * dx + dy * dy <= radius * radius;
}

String _stickerText(BuildContext context,
    {required String uk, required String en}) {
  final code = Localizations.localeOf(context).languageCode.toLowerCase();
  return code == 'uk' ? uk : en;
}
