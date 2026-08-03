import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/file_reassembly.dart';
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_test/flutter_test.dart';

/// Chunks of one file arriving at once must still assemble.
///
/// This is the shape of a real failure, from an iOS device log: a 7-chunk file
/// sent from Android over the relay produced
///
///     SealedBox open FAILED … FileSystemException: An async operation is
///     currently pending, path = '…/cubechat-files/e461330….part'
///
/// twice, and the file never arrived — while the sender showed it delivered,
/// because the relay had accepted it. Each chunk is its own inbound frame, so
/// two were being written to the same RandomAccessFile at once, and
/// `setPosition` + `writeFrom` is two awaits that cannot overlap.
void main() {
  late Directory workDir;

  setUp(() async {
    workDir = await Directory.systemTemp.createTemp('cubechat_reassembly_');
  });

  tearDown(() {
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
  });

  Uint8List fileId([int fill = 7]) => Uint8List(16)..fillRange(0, 16, fill);

  test('chunks fed concurrently assemble to the original bytes', () async {
    const stride = 512;
    const total = 7;
    // Distinct bytes per chunk, so a swapped offset shows up as wrong content
    // rather than merely the wrong length.
    final expected = Uint8List(stride * (total - 1) + 100);
    for (var i = 0; i < expected.length; i++) {
      expected[i] = (i * 31 + 7) & 0xff;
    }

    final reassembler = FileReassembler(workDir: workDir);
    final chunks = [
      for (var seq = 0; seq < total; seq++)
        FileChunk(
          fileId: fileId(),
          seq: seq,
          total: total,
          data: Uint8List.sublistView(
            expected,
            seq * stride,
            seq == total - 1 ? expected.length : (seq + 1) * stride,
          ),
        ),
    ];

    // All at once, deliberately not awaited in turn — this is what the relay
    // burst does, and awaiting each one is what used to hide the bug.
    final results = await Future.wait(chunks.map(reassembler.ingest));

    final assembled = results.whereType<AssembledFile>().toList();
    expect(assembled, hasLength(1),
        reason: 'exactly one chunk completes the transfer');
    expect(assembled.single.bytes, expected.length);
    expect(
      await assembled.single.file.readAsBytes(),
      equals(expected),
      reason: 'concurrent writes must not land at each other\'s offsets',
    );
  });

  test('a burst that arrives out of order still assembles', () async {
    const stride = 256;
    const total = 5;
    final expected = Uint8List(stride * (total - 1) + 40);
    for (var i = 0; i < expected.length; i++) {
      expected[i] = (i * 17 + 3) & 0xff;
    }

    final reassembler = FileReassembler(workDir: workDir);
    final order = [4, 1, 3, 0, 2];
    final results = await Future.wait([
      for (final seq in order)
        reassembler.ingest(FileChunk(
          fileId: fileId(3),
          seq: seq,
          total: total,
          data: Uint8List.sublistView(
            expected,
            seq * stride,
            seq == total - 1 ? expected.length : (seq + 1) * stride,
          ),
        )),
    ]);

    final assembled = results.whereType<AssembledFile>().single;
    expect(await assembled.file.readAsBytes(), equals(expected));
  });
}
