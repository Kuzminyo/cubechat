import 'dart:typed_data';

import 'package:cubechat/core/utils/file_signature.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(List<int> head, {int pad = 0}) =>
    Uint8List.fromList([...head, ...List.filled(pad, 0)]);

void main() {
  group('extensionFromSignature', () {
    test('names the formats people actually send', () {
      expect(
        extensionFromSignature(_bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
        'png',
      );
      expect(extensionFromSignature(_bytes([0xFF, 0xD8, 0xFF, 0xE0])), 'jpg');
      expect(extensionFromSignature(_bytes([0x25, 0x50, 0x44, 0x46, 0x2D])), 'pdf');
      expect(extensionFromSignature(_bytes([0x50, 0x4B, 0x03, 0x04])), 'zip');
    });

    test('reads the brand inside a RIFF container', () {
      // "RIFF" + 4 size bytes + the form type, which is the only thing telling
      // a WebP from a WAV.
      expect(
        extensionFromSignature(_bytes([
          0x52, 0x49, 0x46, 0x46, //
          0, 0, 0, 0,
          0x57, 0x45, 0x42, 0x50,
        ])),
        'webp',
      );
      expect(
        extensionFromSignature(_bytes([
          0x52, 0x49, 0x46, 0x46, //
          0, 0, 0, 0,
          0x57, 0x41, 0x56, 0x45,
        ])),
        'wav',
      );
    });

    test('separates audio from video in an ISO container', () {
      // Both are `ftyp` boxes; handing an .m4a to a video player is the sort of
      // "opened, sort of" this is meant to avoid.
      expect(
        extensionFromSignature(_bytes([
          0, 0, 0, 0x18, //
          0x66, 0x74, 0x79, 0x70,
          0x4D, 0x34, 0x41, 0x20,
        ])),
        'm4a',
      );
      expect(
        extensionFromSignature(_bytes([
          0, 0, 0, 0x18, //
          0x66, 0x74, 0x79, 0x70,
          0x69, 0x73, 0x6F, 0x6D,
        ])),
        'mp4',
      );
    });

    test('says nothing rather than guessing', () {
      // Plain text has no signature, and inventing one would rename a file the
      // system could already have opened.
      expect(extensionFromSignature(_bytes([0x68, 0x65, 0x6C, 0x6C, 0x6F])), isNull);
      expect(extensionFromSignature(Uint8List(0)), isNull);
      // Short reads must not run off the end of the buffer.
      expect(extensionFromSignature(_bytes([0x52, 0x49])), isNull);
    });
  });
}
