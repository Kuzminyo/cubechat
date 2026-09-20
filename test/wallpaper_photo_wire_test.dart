import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_test/flutter_test.dart';

/// A custom photo wallpaper travels as an ordinary image transfer filed under
/// its own [MediaKind], exactly as an avatar does — not as a control frame.
///
/// The control frame carries presets only, and deliberately: a photo in one
/// authenticated packet is a huge frame to push through a link somebody is
/// scrolling a conversation on.
void main() {
  Uint8List id(int b) => Uint8List.fromList(List<int>.filled(16, b));
  Uint8List hash(int b) => Uint8List.fromList(List<int>.filled(32, b));

  group('wallpaper media kind', () {
    test('has a tag of its own, free in the MediaKind space', () {
      // image 0x10, audio 0x30, file 0x50, avatar 0x60 are taken.
      expect(MediaKind.wallpaper.tag, 0x70);
      final tags = MediaKind.values.map((k) => k.tag).toList();
      expect(tags.toSet().length, tags.length, reason: 'tags must be unique');
    });

    test('a manifest round-trips through the wire and back', () {
      final manifest = MediaManifest(
        mediaId: id(7),
        kind: MediaKind.wallpaper,
        // `total` is the chunk count, not a byte count.
        total: 10,
        mime: 'image/jpeg',
        sha256: hash(9),
      );

      final decoded = MediaManifest.decode(manifest.encode());

      expect(decoded.kind, MediaKind.wallpaper);
      expect(decoded.mediaId, manifest.mediaId);
      expect(decoded.total, 10);
      expect(decoded.sha256, manifest.sha256);
      expect(decoded.mime, 'image/jpeg');
    });

    test('a build that predates it drops the manifest rather than guessing',
        () {
      // This is the wanted failure and the reason for a new tag rather than
      // reusing image: an older phone throws on the unknown byte, drops the
      // manifest, then drops the chunks for want of one, and the conversation
      // keeps the backdrop it had. Nothing is rendered wrong and nothing
      // crashes.
      expect(() => MediaKind.fromByte(0x71), throwsFormatException);
    });
  });
}
