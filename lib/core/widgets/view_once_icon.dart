import 'package:flutter/material.dart';

/// The "one look and it is gone" mark: a bomb with a lit fuse and a 1 on it.
///
/// Drawn rather than taken from an icon font because it is not in one. It went
/// through `looks_one` (a numeral in a box, which read as a page number) and
/// then `Symbols.bomb` (a bomb, but somebody else's, and no numeral) before
/// being drawn to say both halves of the promise at once: this is the first
/// and only time it opens.
///
/// A transcription of `design-previews/view-once-icons/svg/01-orbit.svg` on a
/// 24-unit grid, stroked the way the source is — round caps and joins at 1.65
/// units — so it sits beside the Material Symbols in the same bar without
/// looking like a different set.
class ViewOnceIcon extends StatelessWidget {
  const ViewOnceIcon({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final side = size ?? theme.size ?? 24;
    return SizedBox(
      width: side,
      height: side,
      child: CustomPaint(
        painter: _ViewOncePainter(
          color: color ?? theme.color ?? const Color(0xFFFFFFFF),
        ),
      ),
    );
  }
}

class _ViewOncePainter extends CustomPainter {
  const _ViewOncePainter({required this.color});

  final Color color;

  /// The grid the paths are written on, so the whole thing scales by one
  /// number instead of every coordinate being a fraction of the widget.
  static const double _grid = 24;
  static const double _strokeWidth = 1.65;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / _grid;
    canvas.save();
    canvas.scale(k);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    // The body: a square shoulder at the top right, then most of a circle back
    // to where it started. The arc is the large one, which is what makes the
    // shape a bomb rather than a leaf.
    final body = Path()
      ..moveTo(14.5, 7.7)
      ..relativeLineTo(1.2, -1.2)
      ..relativeLineTo(1.8, 1.8)
      ..relativeLineTo(-1.2, 1.2)
      ..arcToPoint(
        const Offset(14.5, 7.7),
        radius: const Radius.circular(7),
        largeArc: true,
      )
      ..close();
    canvas.drawPath(body, paint);

    // The fuse, curling up and away.
    final fuse = Path()
      ..moveTo(16.35, 7.35)
      ..relativeCubicTo(-0.95, -1.55, -0.6, -3.5, 1.5, -3.5)
      ..relativeLineTo(1.3, 0);
    canvas.drawPath(fuse, paint);

    // Three sparks at the end of it.
    canvas.drawLine(const Offset(21, 2.8), const Offset(21, 1.6), paint);
    canvas.drawLine(const Offset(22.1, 3.9), const Offset(23.1, 3.4), paint);
    canvas.drawLine(const Offset(21.9, 5.4), const Offset(22.7, 6.2), paint);

    // The numeral, as a 1 is actually written: a flag and a stem.
    final one = Path()
      ..moveTo(9, 12.2)
      ..relativeLineTo(1.8, -1.2)
      ..relativeLineTo(0, 6);
    canvas.drawPath(one, paint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ViewOncePainter old) => old.color != color;
}
