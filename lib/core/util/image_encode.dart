import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../transport/mtu_budget.dart';

/// Re-encode arbitrary image bytes down to something the BLE mesh can carry —
/// at most [kMaxOutgoingImageBytes].
///
/// The gallery picker path downscales straight from the native [AssetEntity]
/// thumbnailer, which is fast and off-thread for free. Camera captures and
/// edited images arrive as raw bytes with no such shortcut, so this is the
/// bytes-in/bytes-out equivalent, run through [compute] to keep the decode and
/// re-encode off the UI isolate.
///
/// Mirrors the rung strategy the picker uses and the reasoning behind it:
/// pixel dimensions don't predict JPEG size (detail does), so step the
/// dimension *and* quality down together until the encoded bytes come in under
/// budget, and hand back the smallest rung if even that overshoots — a tiny
/// image beats a failed send.
Future<Uint8List?> encodeBytesForMesh(Uint8List src) =>
    compute(_encodeBytesForMesh, src);

Uint8List? _encodeBytesForMesh(Uint8List src) {
  final decoded = img.decodeImage(src);
  if (decoded == null) {
    // Undecodable, but if it already fits it may still be a valid JPEG the
    // decoder simply doesn't support re-reading — send it as-is over failing.
    return src.length <= kMaxOutgoingImageBytes ? src : null;
  }

  const rungs = <({int size, int quality})>[
    (size: 1280, quality: 70),
    (size: 1024, quality: 65),
    (size: 800, quality: 60),
    (size: 640, quality: 55),
    (size: 480, quality: 50),
    (size: 320, quality: 45),
  ];

  Uint8List? smallest;
  for (final rung in rungs) {
    // Only ever downscale — upsizing a small source wastes bytes for no detail.
    final resized = decoded.width > rung.size
        ? img.copyResize(decoded, width: rung.size)
        : decoded;
    final bytes = Uint8List.fromList(img.encodeJpg(resized, quality: rung.quality));
    smallest = bytes;
    if (bytes.length <= kMaxOutgoingImageBytes) return bytes;
  }
  return smallest;
}
