import 'dart:async';

import 'package:flutter/material.dart';

/// Kubi, beside the storage screen's ring.
///
/// Sitting, still, while nothing is happening. When a clear starts he plays
/// his whole routine — gets up, sweeps, sits back down — and goes round again
/// for as long as the clear takes. When it ends he finishes the round he is in
/// rather than vanishing mid-stroke: the routine ends on the very drawing the
/// still is, so swapping back there is invisible. The clear itself does not
/// wait for him.
///
/// Still by default on purpose. An animation running for as long as the
/// screen is open is a frame scheduled every 40 ms for nothing — the backdrop
/// parks its own for the same reason — and a cat that sweeps all the time says
/// nothing; one that gets up when you press the button says it worked.
///
/// The routine is the design preview's (`design-previews/kubi-sit-stand-sweep`)
/// at 256 px instead of 512: drawn at [size] it never needs more, and the
/// original was 8.2 MB of APK; this is 2.7.
class SweepingCat extends StatefulWidget {
  const SweepingCat({super.key, required this.sweeping, this.size = 120});

  final bool sweeping;
  final double size;

  static const String sitting = 'assets/illustrations/kubi-sit.webp';
  static const String sweepingAsset = 'assets/illustrations/kubi-sweep.webp';

  /// One round of the routine: 190 frames at 25 fps.
  static const Duration routine = Duration(milliseconds: 7600);

  @override
  State<SweepingCat> createState() => _SweepingCatState();
}

class _SweepingCatState extends State<SweepingCat> {
  bool _playing = false;
  DateTime? _startedAt;
  Timer? _settle;

  @override
  void didUpdateWidget(SweepingCat old) {
    super.didUpdateWidget(old);
    if (widget.sweeping && !old.sweeping) {
      _start();
    } else if (!widget.sweeping && old.sweeping) {
      _finishRound();
    }
  }

  void _start() {
    _settle?.cancel();
    _settle = null;
    if (_playing) return;
    // From the first frame every time. An animated image left in the cache
    // resumes wherever it was paused, which would start the next clear with
    // him already mid-sweep.
    unawaited(_routine(context).evict());
    setState(() {
      _playing = true;
      _startedAt = DateTime.now();
    });
  }

  /// Sit down at the end of the round in progress.
  void _finishRound() {
    final started = _startedAt;
    if (!_playing || started == null) return;
    final round = SweepingCat.routine.inMilliseconds;
    final into = DateTime.now().difference(started).inMilliseconds % round;
    _settle?.cancel();
    _settle = Timer(Duration(milliseconds: round - into), () {
      if (!mounted) return;
      setState(() {
        _playing = false;
        _startedAt = null;
      });
    });
  }

  int _decodeWidth(BuildContext context) =>
      (widget.size * MediaQuery.devicePixelRatioOf(context)).round();

  // Decoded at the size drawn — an uncapped decode was a measured cost here
  // before (see the perf-triage notes).
  ImageProvider _routine(BuildContext context) => ResizeImage(
        const AssetImage(SweepingCat.sweepingAsset),
        width: _decodeWidth(context),
      );

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animate = _playing && !MediaQuery.disableAnimationsOf(context);
    return ExcludeSemantics(
      child: Image(
        image: animate
            ? _routine(context)
            : ResizeImage(
                const AssetImage(SweepingCat.sitting),
                width: _decodeWidth(context),
              ),
        width: widget.size,
        height: widget.size,
        // No blank frame between the two images.
        gaplessPlayback: true,
      ),
    );
  }
}
