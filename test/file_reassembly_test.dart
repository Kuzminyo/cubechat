import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/file_reassembly.dart';
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _id([int fill = 3]) => Uint8List(16)..fillRange(0, 16, fill);

/// Slice [bytes] the way the sender does: one chunk size chosen up front, so
/// every chunk but the last is exactly [stride] long.
List<FileChunk> _slice(Uint8List bytes, int stride, {Uint8List? id}) {
  final fileId = id ?? _id();
  final total = (bytes.length + stride - 1) ~/ stride;
  return [
    for (var i = 0; i < total; i++)
      FileChunk(
        fileId: fileId,
        seq: i,
        total: total,
        data: Uint8List.sublistView(
          bytes,
          i * stride,
          ((i + 1) * stride).clamp(0, bytes.length),
        ),
      ),
  ];
}

Uint8List _payload(int n) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) & 0xff));

void main() {
  late Directory tmp;
  late FileReassembler r;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cubechat-file-test');
    r = FileReassembler(workDir: tmp);
  });

  tearDown(() async {
    // Partial transfers hold their scratch file open for the whole transfer,
    // and Windows refuses to delete a directory containing an open handle.
    await r.clear();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('reassembles a file that arrives in order', () async {
    final data = _payload(5000);
    AssembledFile? done;
    for (final c in _slice(data, 1024)) {
      done = await r.ingest(c) ?? done;
    }
    expect(done, isNotNull);
    expect(done!.bytes, data.length);
    expect(await done.file.readAsBytes(), equals(data));
  });

  test('reassembles when chunks arrive shuffled', () async {
    // The mesh gives no ordering guarantee — chunks can take different paths
    // and a relay can reorder them. Offsets are computed from the sequence,
    // never from arrival order.
    final data = _payload(5000);
    final chunks = _slice(data, 1024)..shuffle();
    AssembledFile? done;
    for (final c in chunks) {
      done = await r.ingest(c) ?? done;
    }
    expect(done, isNotNull);
    expect(await done!.file.readAsBytes(), equals(data));
  });

  test('handles the final short chunk arriving first', () async {
    // The last chunk is shorter, so it says nothing about the stride. It has
    // to be parked until a full-size chunk reveals it.
    final data = _payload(2500); // 1024, 1024, 452
    final chunks = _slice(data, 1024);
    AssembledFile? done;
    for (final c in [chunks[2], chunks[0], chunks[1]]) {
      done = await r.ingest(c) ?? done;
    }
    expect(done, isNotNull);
    expect(await done!.file.readAsBytes(), equals(data));
  });

  test('a single-chunk transfer completes', () async {
    // Its only chunk is also the final one, so there is no stride to learn.
    // Without special-casing this it would wait forever.
    final data = _payload(300);
    final done = await r.ingest(_slice(data, 1024).single);
    expect(done, isNotNull);
    expect(await done!.file.readAsBytes(), equals(data));
  });

  test('ignores a duplicate chunk instead of counting it twice', () async {
    final data = _payload(3000);
    final chunks = _slice(data, 1024);
    await r.ingest(chunks[0]);
    await r.ingest(chunks[0]);
    expect(r.progressOf(_id()), closeTo(1 / 3, 0.001));
    await r.ingest(chunks[1]);
    final done = await r.ingest(chunks[2]);
    expect(done, isNotNull);
    expect(await done!.file.readAsBytes(), equals(data));
  });

  test('drops a transfer whose chunk sizes are ragged', () async {
    // The sender picks one chunk size per transfer, so a mid-transfer change
    // means the offsets cannot be trusted. Better to lose the transfer than to
    // write bytes at the wrong place and hand over a corrupt file.
    final id = _id(5);
    await r.ingest(
      FileChunk(fileId: id, seq: 0, total: 3, data: Uint8List(1024)),
    );
    await r.ingest(
      FileChunk(fileId: id, seq: 1, total: 3, data: Uint8List(512)),
    );
    expect(r.pendingCount, 0);
  });

  test('refuses more concurrent transfers than the cap', () async {
    final small = FileReassembler(workDir: tmp, maxPendingTransfers: 2);
    for (var i = 0; i < 4; i++) {
      await small.ingest(
        FileChunk(fileId: _id(i + 1), seq: 0, total: 9, data: Uint8List(64)),
      );
    }
    expect(small.pendingCount, 2);
    await small.clear();
  });

  test('refuses a transfer that would exceed the per-file cap', () async {
    final tight = FileReassembler(workDir: tmp, maxBytesPerTransfer: 2000);
    final chunks = _slice(_payload(5000), 1024);
    for (final c in chunks) {
      await tight.ingest(c);
    }
    // Dropped rather than half-written.
    expect(tight.pendingCount, 0);
    expect(tight.bytesBuffered, 0);
    await tight.clear();
  });

  test('refuses to fill the disk across several transfers', () async {
    // The per-transfer cap alone can be multiplied by opening more of them.
    final tight = FileReassembler(
      workDir: tmp,
      maxBytesPerTransfer: 10000,
      maxBytesOnDisk: 3000,
    );
    for (var i = 0; i < 3; i++) {
      await tight.ingest(
        FileChunk(fileId: _id(i + 1), seq: 0, total: 8, data: Uint8List(1400)),
      );
    }
    expect(tight.bytesBuffered, lessThanOrEqualTo(3000));
    await tight.clear();
  });

  test('drops a transfer whose total changes mid-flight', () async {
    final id = _id(6);
    await r.ingest(
      FileChunk(fileId: id, seq: 0, total: 4, data: Uint8List(100)),
    );
    await r.ingest(
      FileChunk(fileId: id, seq: 1, total: 9, data: Uint8List(100)),
    );
    expect(r.pendingCount, 0);
  });

  test('clear() removes partial files from disk', () async {
    await r.ingest(
      FileChunk(fileId: _id(), seq: 0, total: 5, data: Uint8List(256)),
    );
    expect(tmp.listSync().whereType<File>(), isNotEmpty);
    await r.clear();
    expect(r.pendingCount, 0);
    expect(tmp.listSync().whereType<File>(), isEmpty);
  });

  test('expires a transfer nobody feeds', () async {
    final quick =
        FileReassembler(workDir: tmp, staleAfter: const Duration(seconds: -1));
    await quick.ingest(
      FileChunk(fileId: _id(2), seq: 0, total: 5, data: Uint8List(64)),
    );
    // Next ingest runs the collector first.
    await quick.ingest(
      FileChunk(fileId: _id(8), seq: 0, total: 5, data: Uint8List(64)),
    );
    expect(quick.pendingCount, 1);
    await quick.clear();
  });
}
