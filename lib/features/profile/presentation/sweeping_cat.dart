import 'package:flutter/material.dart';

/// Kubi with a broom, above the storage screen's clear button: sitting still
/// while nothing is happening, sweeping while the cache is being cleared.
///
/// Still by default on purpose. An animation running for as long as the
/// screen is open is a frame scheduled every 40 ms for nothing — the backdrop
/// parks its own for the same reason — and a cat that sweeps all the time says
/// nothing; one that starts when you press the button says the button worked.
///
/// The animation is the design preview's (`design-previews/kubi-cache-broom`)
/// at 256 px instead of 512: drawn at [size] it never needs more, and the
/// original was 5.5 MB of APK.
class SweepingCat extends StatelessWidget {
  const SweepingCat({super.key, required this.sweeping, this.size = 120});

  final bool sweeping;
  final double size;

  static const String sitting = 'assets/illustrations/kubi-sit.webp';
  static const String sweepingAsset = 'assets/illustrations/kubi-sweep.webp';

  @override
  Widget build(BuildContext context) {
    final animate = sweeping && !MediaQuery.disableAnimationsOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ExcludeSemantics(
      child: Image.asset(
        animate ? sweepingAsset : sitting,
        width: size,
        height: size,
        // Decoded at the size drawn — an uncapped decode was a measured cost
        // here before (see the perf-triage notes).
        cacheWidth: (size * dpr).round(),
        // No blank frame between the two images.
        gaplessPlayback: true,
      ),
    );
  }
}
