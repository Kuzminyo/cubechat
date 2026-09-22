import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/crypto/file_digest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cubechat_digest_test_');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  // The manifest commits to this digest and the receiver checks the file
  // against it, so the hash moved to another isolate must be the same hash —
  // byte for byte what the in-place streaming hash produced before.
  test('matches SHA-256 of the same bytes hashed in place', () async {
    final bytes = Uint8List.fromList(
      List.generate(300 * 1024 + 17, (i) => (i * 31 + 7) & 0xFF),
    );
    final file = File('${dir.path}${Platform.pathSeparator}clip.mp4');
    await file.writeAsBytes(bytes);

    final digest = await sha256OfFile(file.path);

    expect(digest, (await Sha256().hash(bytes)).bytes);
  });

  test('the empty-string vector', () async {
    final file = File('${dir.path}${Platform.pathSeparator}empty');
    await file.writeAsBytes(const <int>[]);

    final hex = (await sha256OfFile(file.path))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    expect(
      hex,
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
  });
}
