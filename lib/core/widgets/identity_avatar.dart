import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../identity/avatar_controller.dart';
import '../theme/colors.dart';
import '../util/ui_activity.dart';

/// Deterministic gradient avatar from a stable seed (e.g. peer pubkey).
class IdentityAvatar extends StatelessWidget {
  const IdentityAvatar({
    super.key,
    required this.seed,
    required this.label,
    this.size = 44,
    this.online = false,
    this.heroTag,
    this.imageBytes,
  });

  final String seed;
  final String label;
  final double size;
  final bool online;

  /// A picture to draw instead of the generated gradient. The gradient is the
  /// fallback rather than the other way round: every identity has one, so the
  /// avatar is never empty while a photo is missing, loading, or unreadable.
  final Uint8List? imageBytes;

  /// When non-null, wraps the avatar in a Hero for shared-element transitions.
  final String? heroTag;

  /// The gradient a seed maps to. Exposed because the profile cover paints the
  /// same colours across the whole header when there is no photo — two
  /// hand-picked palettes would drift apart.
  static List<Color> paletteFor(String seed) =>
      _palettes[seed.hashCode.abs() % _palettes.length];

  static const List<List<Color>> _palettes = [
    [Color(0xFF2EDB8F), Color(0xFF7FD9A6)],
    [Color(0xFF34D399), Color(0xFFA3E635)],
    [Color(0xFF7FD9A6), Color(0xFF2EDB8F)],
    [Color(0xFFA3E635), Color(0xFF34D399)],
    [Color(0xFF2EDB8F), Color(0xFFA3E635)],
  ];

  @override
  Widget build(BuildContext context) {
    final palette = paletteFor(seed);
    final initials = _initials(label);
    final photo = imageBytes;
    final body = SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: photo == null
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: palette,
                    )
                  : null,
              image: photo == null
                  ? null
                  : DecorationImage(
                      // Decoded at the size actually drawn, not at the size
                      // stored. The avatar is full HD so the profile cover
                      // stays sharp; handing those bytes to a 44 px circle
                      // unscaled would put ~15 MB of pixels in the image cache
                      // per distinct size, and every row of a list pays for it.
                      image: ResizeImage(
                        MemoryImage(photo),
                        width: _decodePx(context, size),
                        height: _decodePx(context, size),
                        policy: ResizeImagePolicy.fit,
                      ),
                      fit: BoxFit.cover,
                    ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.2),
                width: 1,
              ),
            ),
            alignment: Alignment.center,
            // Initials belong to the gradient. Over a photo they would sit on
            // the person's face.
            child: photo != null
                ? null
                : Text(
                    initials,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: size * 0.38,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
          if (online)
            Positioned(
              right: 0,
              bottom: 0,
              child: _OnlineDot(size: size * 0.28),
            ),
        ],
      ),
    );

    if (heroTag == null) return body;
    return Hero(
      tag: heroTag!,
      flightShuttleBuilder: (_, animation, __, ___, ____) {
        return ScaleTransition(
          scale: Tween<double>(begin: 1.0, end: 1.0).animate(animation),
          child: body,
        );
      },
      child: body,
    );
  }

  /// Pixels to decode for a circle [logical] points across.
  ///
  /// Rounded up to a power of two so the handful of sizes the app draws (44,
  /// 48, 72, and the cover) collapse onto a few cache entries instead of one
  /// per call site — the image cache keys on the decode size, and near-misses
  /// would each hold their own full copy.
  static int _decodePx(BuildContext context, double logical) {
    final px = logical * MediaQuery.devicePixelRatioOf(context);
    var bucket = 64;
    while (bucket < px && bucket < AvatarController.storedSize) {
      bucket *= 2;
    }
    // The doubling can overshoot the source — asking for 2048 from a 1920
    // original just makes the decoder upscale, which costs memory and adds no
    // detail. The stored size is the ceiling.
    return bucket > AvatarController.storedSize
        ? AvatarController.storedSize
        : bucket;
  }

  String _initials(String text) {
    final parts = text.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts[1].characters.first)
        .toUpperCase();
  }
}

class _OnlineDot extends StatefulWidget {
  const _OnlineDot({required this.size});

  final double size;

  @override
  State<_OnlineDot> createState() => _OnlineDotState();
}

class _OnlineDotState extends State<_OnlineDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  late final Animation<double> _glow = Tween<double>(
    begin: 0.35,
    end: 0.60,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  @override
  void initState() {
    super.initState();
    UiActivity.instance.isQuiet.addListener(_applyActivity);
    _applyActivity();
  }

  /// Pulse while the interface is in use; park when it goes quiet.
  ///
  /// A running ticker means a frame scheduled every vsync. The aurora already
  /// parks itself when nothing is happening; without this the dot kept the app
  /// awake anyway — a dozen of them on a chat list held the compositor at the
  /// display's full refresh rate while the user did nothing but read.
  ///
  /// Parking leaves the glow wherever it was, which is fine: the value only
  /// ranges over 0.35–0.60, so any frozen frame reads as a lit dot rather than
  /// a half-drawn one.
  void _applyActivity() {
    if (!mounted) return;
    if (UiActivity.instance.isQuiet.value) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    UiActivity.instance.isQuiet.removeListener(_applyActivity);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // This dot sits on every avatar, so it is on screen once per visible chat
    // row — and it never stops animating. Two things keep that affordable:
    //
    //  * the blur is a fixed radius and only the glow layer's *opacity*
    //    animates, so the shadow rasterizes once and the compositor re-blends
    //    it. Animating blurRadius (as this used to) re-rasterizes a blur per
    //    dot per frame, which at 120 Hz is most of a frame budget spent on
    //    decoration.
    //  * the RepaintBoundary keeps the repaint inside the dot instead of
    //    dirtying the whole list row behind it.
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            FadeTransition(
              opacity: _glow,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.online,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.online,
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: AppColors.online,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.bgDeep, width: 2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
