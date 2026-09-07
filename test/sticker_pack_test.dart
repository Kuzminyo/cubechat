// The pack in the code and the pack on disk have to be the same pack.
//
// Everything here fails silently otherwise. A name in the list with no file
// behind it is a picker cell that draws nothing and a sticker that cannot be
// sent; a file with no name in the list is seventeen megabytes of APK carrying
// something nobody can reach. Neither shows up in a build, in the analyzer, or
// in any other test — the assets are looked up by a string at runtime.
import 'dart:convert';
import 'dart:io';

import 'package:cubechat/features/stickers/data/builtin_stickers.dart';
import 'package:cubechat/features/stickers/data/sticker_pack.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dir = Directory('assets/stickers');

  Set<String> filesWith(String extension) => dir
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n.endsWith(extension))
      .map((n) => n.substring(0, n.length - extension.length))
      .toSet();

  test('every sticker in the list has both of its files', () {
    final animations = filesWith('.webp');
    final stills = filesWith('.png');
    for (final name in StickerPack.all) {
      expect(animations, contains(name), reason: '$name has no animation');
      expect(stills, contains(name), reason: '$name has no still');
    }
  });

  test('every file on disk is in the list', () {
    // The other direction, and the one that costs megabytes rather than
    // pixels: artwork built and then forgotten still ships.
    expect(filesWith('.webp'), StickerPack.all.toSet());
    expect(filesWith('.png'), StickerPack.all.toSet());
  });

  test('the list matches what the build script wrote', () {
    final manifest = jsonDecode(
      File('assets/stickers/manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final cats = (manifest['cats'] as List).cast<String>().toSet();
    final faces = (manifest['emoji'] as List).cast<String>().toSet();
    expect(StickerPack.cats.toSet(), cats);
    expect(StickerPack.faces.toSet(), faces);
  });

  test('nothing is listed twice', () {
    expect(StickerPack.all.toSet(), hasLength(StickerPack.all.length));
  });

  test('every sticker has an emoji to be called by', () {
    // It is what a chat row and a reply quote show in place of a picture they
    // cannot draw. A sticker with none reads as "Sticker" and nothing else.
    for (final name in StickerPack.all) {
      expect(StickerPack.glyphFor[name], isNotNull, reason: name);
    }
    expect(BuiltinStickers.emojiFor('cat-wave'), '👋');
  });

  group('the face a single emoji turns into', () {
    test('is one of the drawn faces, never a cat', () {
      // Typing 👋 must not silently become a cat. The cat is something
      // somebody picks on purpose.
      for (final name in StickerPack.faceForGlyph.values) {
        expect(StickerPack.faces, contains(name));
      }
    });

    test('covers every drawn face', () {
      expect(StickerPack.faceForGlyph.values.toSet(),
          StickerPack.faces.toSet());
    });

    test('has no two faces claiming the same emoji', () {
      // A duplicate would make one of them unreachable, and which one would
      // depend on map order — the kind of thing that changes under a rename.
      final glyphs = [for (final n in StickerPack.faces) StickerPack.glyphFor[n]];
      expect(glyphs.toSet(), hasLength(glyphs.length));
    });

    test('finds the ones somebody actually sends alone', () {
      expect(StickerPack.faceForGlyph['❤️'], 'emoji-heart');
      expect(StickerPack.faceForGlyph['😂'], 'emoji-laugh');
      expect(StickerPack.faceForGlyph['👍'], 'emoji-approve');
      expect(StickerPack.faceForGlyph['🔥'], 'emoji-fire');
    });

    test('leaves an emoji with no drawing alone', () {
      expect(StickerPack.faceForGlyph['🦄'], isNull);
    });
  });

  test('the asset paths are the ones the bundle declares', () {
    // `pubspec.yaml` lists the directory, so a path that does not start with
    // it is not in the bundle at all — and the failure is a runtime exception
    // in an image, which is to say a blank square.
    expect(StickerPack.animation('cat-wave'), 'assets/stickers/cat-wave.webp');
    expect(StickerPack.still('cat-wave'), 'assets/stickers/cat-wave.png');
    expect(File(StickerPack.animation('cat-wave')).existsSync(), isTrue);
  });
}
