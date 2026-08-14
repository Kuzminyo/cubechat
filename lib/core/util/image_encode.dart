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

/// Re-encode a picture as the square, transparent-capable PNG a sticker is.
///
/// Not [encodeBytesForMesh], because that ends in a JPEG: a sticker's whole
/// shape comes from the pixels it does *not* draw, and JPEG has no way to say
/// "nothing here" — every transparent pixel would come back as a white (or
/// black) rectangle around the picture. PNG keeps the alpha channel, so a
/// cut-out stays a cut-out.
///
/// The ladder is dimension-only for the same reason: PNG has no quality knob,
/// so when 512 px overshoots the budget the only thing left to spend is size.
/// Returns null when even the smallest rung is too big for the mesh, so the
/// caller can say so instead of queueing something that will never arrive.
Future<Uint8List?> encodeStickerPng(Uint8List src) => compute(_encodeSticker, src);

Uint8List? _encodeSticker(Uint8List src) {
  final decoded = img.decodeImage(src);
  if (decoded == null) {
    return src.length <= kMaxOutgoingImageBytes ? src : null;
  }
  // Trimmed to what is actually drawn before anything else: a picture saved
  // out of another app is often a small shape in the middle of a large
  // transparent canvas, and every one of those empty rows is bytes on the wire
  // and empty space in the bubble.
  final trimmed = img.trim(decoded, mode: img.TrimMode.transparent);
  final source = trimmed.width > 8 && trimmed.height > 8 ? trimmed : decoded;

  const rungs = <int>[512, 384, 320, 256, 192];
  Uint8List? smallest;
  for (final side in rungs) {
    final longest =
        source.width > source.height ? source.width : source.height;
    final resized = longest > side
        ? (source.width >= source.height
            ? img.copyResize(source, width: side)
            : img.copyResize(source, height: side))
        : source;
    final bytes = Uint8List.fromList(img.encodePng(resized));
    smallest = bytes;
    if (bytes.length <= kMaxOutgoingImageBytes) return bytes;
  }
  return smallest != null && smallest.length <= kMaxOutgoingImageBytes
      ? smallest
      : null;
}

/// Square-crop and re-encode a picture small enough to be broadcast in one
/// frame, for a channel's photo.
///
/// A room's picture cannot be requested the way a person's can — there is no
/// single member to ask — so it is broadcast, and a broadcast has to fit one
/// unfragmentable frame. That caps it near 40 KB, which is why this ladder
/// bottoms out far below [encodeBytesForMesh]'s. Returns null when even the
/// smallest rung overshoots [maxBytes], so the caller can say so rather than
/// send something that will never arrive.
Future<Uint8List?> encodeChannelAvatar(Uint8List src, {required int maxBytes}) =>
    compute(
      (({Uint8List src, int maxBytes}) args) =>
          _encodeChannelAvatar(args.src, args.maxBytes),
      (src: src, maxBytes: maxBytes),
    );

Uint8List? _encodeChannelAvatar(Uint8List src, int maxBytes) {
  final decoded = img.decodeImage(src);
  if (decoded == null) return src.length <= maxBytes ? src : null;

  final side = decoded.width < decoded.height ? decoded.width : decoded.height;
  final square = img.copyCrop(
    decoded,
    x: (decoded.width - side) ~/ 2,
    y: (decoded.height - side) ~/ 2,
    width: side,
    height: side,
  );

  const rungs = <({int size, int quality})>[
    (size: 512, quality: 82),
    (size: 512, quality: 70),
    (size: 384, quality: 70),
    (size: 256, quality: 65),
  ];
  for (final rung in rungs) {
    final resized = square.width > rung.size
        ? img.copyResize(square, width: rung.size, height: rung.size)
        : square;
    final bytes =
        Uint8List.fromList(img.encodeJpg(resized, quality: rung.quality));
    if (bytes.length <= maxBytes) return bytes;
  }
  return null;
}
