import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:image/image.dart' as img;

import '../storage/hive_cipher.dart';
import '../storage/hive_init.dart';

/// The user's own avatar picture, or null when they haven't set one and the
/// generated identity gradient stands in.
///
/// Stored square and small on purpose. It is only ever drawn inside a circle
/// at 72 px or less, so anything past a couple of hundred pixels is invisible
/// detail that still has to be decoded on every rebuild — and it lives in the
/// encrypted settings box, which is read whole.
///
/// The image is re-encoded rather than stored as picked: a gallery photo is
/// several megabytes of data we would be carrying around forever to draw a
/// thumbnail.
class AvatarController extends Notifier<Uint8List?> {
  static const _key = 'avatar.jpeg';

  /// Side of the stored square. The profile can expand the avatar nearly to
  /// full-screen, so keep enough detail for modern high-density displays.
  static const int storedSize = 1024;

  /// JPEG quality for the stored copy. Keeps full-screen avatars crisp without
  /// retaining the multi-megabyte original gallery image.
  static const int quality = 90;

  Box<dynamic>? _box;

  /// Completes once the settings box is open. Opening it goes through the
  /// platform keystore, which is slow enough that a user can easily pick a
  /// photo first — and a write against a null box is silently dropped, so the
  /// avatar would appear to take and then be gone on the next launch.
  late Future<void> _ready;

  /// Set once the user has chosen a picture this session, so a slow disk read
  /// arriving afterwards cannot put the old one back.
  bool _userSet = false;

  @override
  Uint8List? build() {
    _ready = _load();
    return null;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      if (_userSet) return;
      final stored = box.get(_key);
      if (stored is Uint8List && stored.isNotEmpty) {
        state = stored;
      } else if (stored is List<int> && stored.isNotEmpty) {
        // Hive can hand back a plain List<int> depending on how it was written.
        state = Uint8List.fromList(stored);
      }
    } catch (e) {
      debugPrint('Avatar load failed: $e');
    }
  }

  /// Square-crop, downscale and store [source]. Returns false when the bytes
  /// could not be decoded as an image, so the caller can say so rather than
  /// silently doing nothing.
  Future<bool> setFromBytes(Uint8List source) async {
    final encoded = await compute(_squareThumbnail, source);
    if (encoded == null) return false;
    _userSet = true;
    state = encoded;
    await _ready;
    try {
      await _box?.put(_key, encoded);
    } catch (e) {
      debugPrint('Avatar persist failed: $e');
    }
    return true;
  }

  Future<void> clear() async {
    _userSet = true;
    state = null;
    await _ready;
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('Avatar clear failed: $e');
    }
  }

  /// Back to no picture — used by Emergency Wipe, which restores every setting
  /// to what a fresh install would have.
  Future<void> reset() => clear();
}

/// Centre-crop to a square, resize to [AvatarController.storedSize] and encode
/// as JPEG. Runs off the UI isolate: decoding a full-resolution gallery photo
/// blocks long enough to drop frames.
Uint8List? _squareThumbnail(Uint8List source) {
  final decoded = img.decodeImage(source);
  if (decoded == null) return null;

  final side = decoded.width < decoded.height ? decoded.width : decoded.height;
  final square = img.copyCrop(
    decoded,
    x: (decoded.width - side) ~/ 2,
    y: (decoded.height - side) ~/ 2,
    width: side,
    height: side,
  );
  // Only ever shrink. Upscaling a small picture would add bytes without adding
  // detail.
  final sized = side > AvatarController.storedSize
      ? img.copyResize(
          square,
          width: AvatarController.storedSize,
          height: AvatarController.storedSize,
        )
      : square;
  return Uint8List.fromList(
    img.encodeJpg(sized, quality: AvatarController.quality),
  );
}

final avatarProvider = NotifierProvider<AvatarController, Uint8List?>(
  AvatarController.new,
);
