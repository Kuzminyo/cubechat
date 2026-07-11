import 'dart:typed_data';

import 'package:cubechat/core/transport/image_reassembly.dart';
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _id(int seed) =>
    Uint8List.fromList(List.generate(ImageChunk.idLen, (i) => (seed + i) & 0xFF));

Uint8List _data(int seed, int len) =>
    Uint8List.fromList(List.generate(len, (i) => (seed + i) & 0xFF));

ImageChunk _imgChunk(Uint8List id, int seq, int total, Uint8List data) =>
    ImageChunk(imageId: id, seq: seq, total: total, mime: 'image/png', data: data);

AudioChunk _audChunk(Uint8List id, int seq, int total, Uint8List data) => AudioChunk(
      audioId: id,
      seq: seq,
      total: total,
      durationMs: 4200,
      mime: 'audio/aac',
      data: data,
    );

void main() {
  group('ImageReassembler', () {
    test('a partial transfer returns null until the last chunk lands', () {
      final r = ImageReassembler();
      final id = _id(1);
      expect(r.ingest(_imgChunk(id, 0, 3, _data(0, 4))), isNull);
      expect(r.ingest(_imgChunk(id, 1, 3, _data(4, 4))), isNull);
      final done = r.ingest(_imgChunk(id, 2, 3, _data(8, 4)));
      expect(done, isNotNull);
    });

    test('assembles chunks in seq order regardless of arrival order', () {
      final r = ImageReassembler();
      final id = _id(2);
      // Arrive out of order: 2, 0, 1.
      r.ingest(_imgChunk(id, 2, 3, _data(20, 2)));
      r.ingest(_imgChunk(id, 0, 3, _data(0, 2)));
      final done = r.ingest(_imgChunk(id, 1, 3, _data(10, 2)));
      expect(done, isNotNull);
      // Expected = data(0,2) ++ data(10,2) ++ data(20,2).
      final expected = Uint8List.fromList(
        [..._data(0, 2), ..._data(10, 2), ..._data(20, 2)],
      );
      expect(done!.bytes, expected);
      expect(done.mime, 'image/png');
      expect(done.imageId, id);
    });

    test('single-chunk image completes immediately', () {
      final r = ImageReassembler();
      final id = _id(3);
      final done = r.ingest(_imgChunk(id, 0, 1, _data(7, 5)));
      expect(done, isNotNull);
      expect(done!.bytes, _data(7, 5));
    });

    test('a duplicate seq does not falsely complete the image', () {
      final r = ImageReassembler();
      final id = _id(4);
      // total=2 but we send seq 0 twice — must not complete on the second.
      expect(r.ingest(_imgChunk(id, 0, 2, _data(0, 3))), isNull);
      expect(r.ingest(_imgChunk(id, 0, 2, _data(0, 3))), isNull);
      final done = r.ingest(_imgChunk(id, 1, 2, _data(30, 3)));
      expect(done, isNotNull);
    });

    test('two different image ids reassemble independently', () {
      final r = ImageReassembler();
      final a = _id(5);
      final b = _id(50);
      r.ingest(_imgChunk(a, 0, 2, _data(0, 2)));
      r.ingest(_imgChunk(b, 0, 2, _data(100, 2)));
      expect(r.ingest(_imgChunk(a, 1, 2, _data(2, 2))), isNotNull);
      expect(r.ingest(_imgChunk(b, 1, 2, _data(102, 2))), isNotNull);
    });

    test('a total mismatch discards the buffer for that image', () {
      final r = ImageReassembler();
      final id = _id(6);
      r.ingest(_imgChunk(id, 0, 3, _data(0, 2)));
      // Same id, contradictory total — buffer is dropped, returns null.
      expect(r.ingest(_imgChunk(id, 1, 4, _data(2, 2))), isNull);
      // The next chunk starts a fresh buffer at total=2 and can complete.
      expect(r.ingest(_imgChunk(id, 0, 2, _data(0, 2))), isNull);
      expect(r.ingest(_imgChunk(id, 1, 2, _data(2, 2))), isNotNull);
    });

    test('a stalled partial transfer is GC-ed after staleAfter', () async {
      final r = ImageReassembler(staleAfter: const Duration(milliseconds: 30));
      final id = _id(7);
      r.ingest(_imgChunk(id, 0, 2, _data(0, 2)));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      // The next ingest runs _gc first, dropping the stale seq-0 buffer, so
      // seq 1 starts fresh and cannot complete on its own.
      expect(r.ingest(_imgChunk(id, 1, 2, _data(2, 2))), isNull);
    });
  });

  group('AudioReassembler', () {
    test('assembles out-of-order chunks and carries duration + mime', () {
      final r = AudioReassembler();
      final id = _id(8);
      r.ingest(_audChunk(id, 1, 2, _data(10, 3)));
      final done = r.ingest(_audChunk(id, 0, 2, _data(0, 3)));
      expect(done, isNotNull);
      expect(
        done!.bytes,
        Uint8List.fromList([..._data(0, 3), ..._data(10, 3)]),
      );
      expect(done.durationMs, 4200);
      expect(done.mime, 'audio/aac');
      expect(done.audioId, id);
    });

    test('a partial audio transfer returns null', () {
      final r = AudioReassembler();
      final id = _id(9);
      expect(r.ingest(_audChunk(id, 0, 2, _data(0, 3))), isNull);
    });
  });
}
