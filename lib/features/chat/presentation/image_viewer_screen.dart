import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';

/// Full-screen pinch-zoom viewer for a single chat image. The image bubble
/// in the chat list pushes this route on tap; the [heroTag] keeps the
/// transition smooth on iOS-style swipe-back.
class ImageViewerScreen extends StatelessWidget {
  const ImageViewerScreen({
    super.key,
    required this.imagePath,
    required this.heroTag,
  });

  final String imagePath;
  final Object heroTag;

  @override
  Widget build(BuildContext context) {
    final file = File(imagePath);
    final exists = file.existsSync();
    return Scaffold(
      backgroundColor: Colors.black,
      // Tap anywhere outside the image to dismiss — same affordance as
      // the system gallery app.
      body: GestureDetector(
        onTap: () => Navigator.of(context).maybePop(),
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: Center(
                  child: exists
                      ? Hero(
                          tag: heroTag,
                          child: InteractiveViewer(
                            // Generous bounds — pinch up to 8x for detail,
                            // pull back to 0.6 to let the user feel the
                            // limit before bouncing.
                            minScale: 0.6,
                            maxScale: 8,
                            clipBehavior: Clip.none,
                            child: Image.file(
                              file,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => _missing(),
                            ),
                          ),
                        )
                      : _missing(),
                ),
              ),
              Positioned(
                top: 8,
                left: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 24),
                  onPressed: () => Navigator.of(context).maybePop(),
                  tooltip: 'Close',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _missing() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.broken_image_outlined,
              color: AppColors.textOnGlassDim,
              size: 56,
            ),
            const SizedBox(height: 12),
            Text(
              'image not available',
              style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
            ),
          ],
        ),
      );
}
