import 'dart:typed_data';

/// The extension a file's own first bytes say it should have, or null.
///
/// Exists for the files that arrived before the app was careful about types.
/// An older build stored an attachment under an id with no extension and,
/// often, no recorded MIME either — so opening it asked Android to find a
/// handler for "some bytes at a path with no suffix", which resolves to
/// nothing on any phone. The bytes themselves are the one description that
/// cannot have been lost: every format here announces itself in its first
/// dozen bytes, and that is enough to hand the system a name it can route.
///
/// Deliberately short. This is not a format database — it is the handful of
/// things people actually send each other, plus the ZIP container that the
/// office formats hide inside (which is why a `.zip` guess is right often
/// enough to be useful and never destructive: nothing is rewritten, a copy is
/// made under a better name).
String? extensionFromSignature(Uint8List header) {
  bool startsWith(List<int> magic, {int offset = 0}) {
    if (header.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (header[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'png';
  if (startsWith([0xFF, 0xD8, 0xFF])) return 'jpg';
  if (startsWith([0x47, 0x49, 0x46, 0x38])) return 'gif'; // GIF8
  if (startsWith([0x25, 0x50, 0x44, 0x46])) return 'pdf'; // %PDF
  if (startsWith([0x42, 0x4D])) return 'bmp'; // BM
  if (startsWith([0x49, 0x49, 0x2A, 0x00]) ||
      startsWith([0x4D, 0x4D, 0x00, 0x2A])) {
    return 'tif';
  }
  if (startsWith([0x4F, 0x67, 0x67, 0x53])) return 'ogg'; // OggS
  if (startsWith([0x66, 0x4C, 0x61, 0x43])) return 'flac'; // fLaC
  if (startsWith([0x1A, 0x45, 0xDF, 0xA3])) return 'mkv'; // EBML, also webm
  if (startsWith([0x52, 0x61, 0x72, 0x21])) return 'rar'; // Rar!
  if (startsWith([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])) return '7z';
  if (startsWith([0x1F, 0x8B])) return 'gz';
  if (startsWith([0x49, 0x44, 0x33]) || startsWith([0xFF, 0xFB])) return 'mp3';

  // RIFF containers name themselves four bytes in.
  if (startsWith([0x52, 0x49, 0x46, 0x46])) {
    if (startsWith([0x57, 0x45, 0x42, 0x50], offset: 8)) return 'webp';
    if (startsWith([0x57, 0x41, 0x56, 0x45], offset: 8)) return 'wav';
    if (startsWith([0x41, 0x56, 0x49, 0x20], offset: 8)) return 'avi';
  }

  // ISO base media: the brand at offset 8 separates video from audio, which
  // matters — handing a .m4a to a video player is the kind of "opened, sort
  // of" this is meant to avoid.
  if (startsWith([0x66, 0x74, 0x79, 0x70], offset: 4)) {
    if (startsWith([0x4D, 0x34, 0x41], offset: 8)) return 'm4a';
    if (startsWith([0x71, 0x74], offset: 8)) return 'mov';
    return 'mp4';
  }

  // PK\x03\x04 — a plain zip, and also every OOXML and OpenDocument file.
  // Guessing which would need the central directory read; zip is the honest
  // answer and still opens in an archiver rather than nothing at all.
  if (startsWith([0x50, 0x4B, 0x03, 0x04])) return 'zip';

  return null;
}
