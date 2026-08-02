import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Sha256;
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

  /// Side of the stored square. Full HD, so the profile cover — which fills
  /// the screen width — is still sharp on a 3x display.
  ///
  /// This is the *stored* size, not the decoded one. Everywhere the avatar is
  /// drawn small, [IdentityAvatar] decodes it down to the circle it is filling;
  /// without that a 44 px row avatar would inflate to 1920x1920x4 bytes — about
  /// 15 MB — in the image cache, which is how a picture this size turns into a
  /// scrolling problem.
  static const int storedSize = 1920;

  /// JPEG quality for the stored copy. Keeps a full-screen avatar crisp without
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
    _shareable = null; // a new picture invalidates the derived copy
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
    _shareable = null;
    await _ready;
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('Avatar clear failed: $e');
    }
  }

  /// Side of the copy that goes to other people.
  ///
  /// Sized from the largest place it is drawn, which is the contact profile's
  /// hero circle: `width * 0.48` is ~173 pt on a 360 pt phone, and at 3x that
  /// is 518 physical pixels. 128 was picked for a 44 px row and 320 still left
  /// the big circle upscaling; 512 covers it.
  static const int shareSize = 512;

  /// Sizes to fall back through when the picture will not fit [shareByteBudget]
  /// even at the lowest quality. A smaller sharp image beats a larger smeared
  /// one, and beats not arriving at all.
  static const List<int> shareSizeLadder = [512, 384, 256];

  /// Qualities to try at each size, best first.
  static const List<int> shareQualityLadder = [82, 74, 66, 58, 50];

  /// Hard ceiling on the bytes we will *send*.
  ///
  /// Not a matter of taste — it is what the BLE link-layer fragmenter can
  /// carry. On a conservative 185-byte ATT MTU a frame splits into at most
  /// 255 slices of 167 bytes = 42,585 bytes, and the envelope, SealedBox and
  /// signature take ~192 of that. A frame above the limit cannot be split, so
  /// it is not "slow", it is undeliverable. 36 KB leaves real margin under the
  /// ~42.4 KB that arithmetic allows.
  static const int shareByteBudget = 36864;

  ({Uint8List jpeg, Uint8List hash})? _shareable;

  /// The small copy handed to peers, with its SHA-256 — the digest we announce
  /// and the one they check the bytes against.
  ///
  /// Cached because it is recomputed on nothing but a change of picture, and
  /// re-encoding a JPEG for every peer that asks would be work per *request*
  /// rather than per *avatar*. Null when the user has no picture set.
  Future<({Uint8List jpeg, Uint8List hash})?> shareable() async {
    final source = state;
    if (source == null) return null;
    final cached = _shareable;
    if (cached != null) return cached;
    final jpeg = await compute(_shareThumbnail, source);
    if (jpeg == null) return null;
    final hash = Uint8List.fromList((await Sha256().hash(jpeg)).bytes);
    return _shareable = (jpeg: jpeg, hash: hash);
  }

  /// Just the digest, for the announcement. Null when there is no picture, and
  /// the announcement then carries all-zero.
  Future<Uint8List?> shareableHash() async => (await shareable())?.hash;

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

/// Re-encode the stored avatar down to the size that crosses the wire. Runs off
/// the UI isolate like [_squareThumbnail]: the stored copy is a 1920px JPEG and
/// decoding one blocks long enough to drop frames.
Uint8List? _shareThumbnail(Uint8List stored) {
  final decoded = img.decodeImage(stored);
  if (decoded == null) return null;

  // Step down until it fits the send budget: quality first at the target size,
  // then a smaller size. A fixed quality cannot work here — how many bytes a
  // JPEG costs depends on the picture, and a busy photo at 512/82 can be twice
  // a plain one. Overshooting is not a slow avatar, it is a frame the BLE
  // fragmenter refuses to split, so the cap has to be met by construction
  // rather than checked afterwards.
  Uint8List? best;
  for (final side in AvatarController.shareSizeLadder) {
    // Already square — the stored copy was centre-cropped on the way in.
    final sized = decoded.width > side
        ? img.copyResize(decoded, width: side, height: side)
        : decoded;
    for (final q in AvatarController.shareQualityLadder) {
      final bytes = Uint8List.fromList(img.encodeJpg(sized, quality: q));
      // Keep the smallest attempt seen, so a pathological picture still ends up
      // with *something* to send rather than nothing.
      if (best == null || bytes.length < best.length) best = bytes;
      if (bytes.length <= AvatarController.shareByteBudget) return bytes;
    }
  }
  return best;
}

final avatarProvider = NotifierProvider<AvatarController, Uint8List?>(
  AvatarController.new,
);
