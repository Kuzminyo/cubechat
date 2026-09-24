import 'dart:typed_data';

import 'package:cubechat/features/airdrop/data/wifi_lane_codec.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Not a gate: prints what the Wi-Fi lane's framing and crypto cost per
/// megabyte on this machine, so a change to the codec can say what it did.
/// Only the correctness of the round trip is asserted.
void main() {
  test(
    'frame + open 32 MiB through the codec (prints MB/s)',
    () async {
    const records = 512; // 512 × 64 KiB = 32 MiB
    const mib = records * WifiLaneCodec.dataBytes / (1024 * 1024);
    final key = Uint8List.fromList(List.generate(32, (i) => i * 3));
    final body = Uint8List(WifiLaneCodec.dataBytes);
    for (var i = 0; i < body.length; i++) {
      body[i] = i & 0xFF;
    }

    final tx = WifiLaneCipher(key, WifiDirection.toReceiver);
    final sw = Stopwatch()..start();
    final sealed = <Uint8List>[];
    // 16 records per seal, as the sender reads 1 MiB at a time.
    for (var i = 0; i < records; i += 16) {
      sealed.addAll(
        await tx.seal([
          for (var j = 0; j < 16; j++) WifiRecord(WifiRecordKind.data, body),
        ]),
      );
    }
    final sealMs = sw.elapsedMilliseconds;

    // The byte stream as TCP hands it over: framed records cut into 64 KiB
    // chunks that do not line up with them.
    sw.reset();
    final framed = BytesBuilder(copy: false);
    for (final s in sealed) {
      framed.add(WifiLaneCodec.frame(s));
    }
    final stream = framed.takeBytes();
    final frameMs = sw.elapsedMilliseconds;

    // The framer alone: what the receiving isolate spends before any crypto.
    sw.reset();
    final framerOnly = WifiRecordFramer();
    var cut = 0;
    const read = 64 * 1024 + 7;
    for (var at = 0; at < stream.length; at += read) {
      final end = at + read > stream.length ? stream.length : at + read;
      framerOnly.add(Uint8List.sublistView(stream, at, end));
      cut += framerOnly.take().length;
    }
    final takeMs = sw.elapsedMilliseconds;
    expect(cut, records);

    Future<(int, int)> run(int batchBytes) async {
      final rx = WifiLaneCipher(key, WifiDirection.toReceiver);
      final framer = WifiRecordFramer();
      final pending = <Uint8List>[];
      var pendingBytes = 0;
      var opened = 0;
      var hops = 0;
      Future<void> flush() async {
        if (pending.isEmpty) return;
        final got = await rx.open(List.of(pending));
        hops++;
        for (final r in got) {
          expect(r.body.length, WifiLaneCodec.dataBytes);
          opened++;
        }
        pending.clear();
        pendingBytes = 0;
      }

      const chunk = 64 * 1024 + 7;
      for (var at = 0; at < stream.length; at += chunk) {
        final end = at + chunk > stream.length ? stream.length : at + chunk;
        framer.add(Uint8List.sublistView(stream, at, end));
        for (final s in framer.take()) {
          pending.add(s);
          pendingBytes += s.length;
        }
        if (pendingBytes >= batchBytes) await flush();
      }
      await flush();
      expect(opened, records);
      return (opened, hops);
    }

    sw.reset();
    final (_, perChunkHops) = await run(1);
    final perChunkMs = sw.elapsedMilliseconds;
    sw.reset();
    final (_, batchedHops) = await run(1024 * 1024);
    final batchedMs = sw.elapsedMilliseconds;

    String rate(int ms) => (mib / (ms / 1000)).toStringAsFixed(1);
    debugPrint(
      '[BENCH] wifi codec, ${mib.toStringAsFixed(0)} MiB: '
      'seal ${rate(sealMs)} MB/s ($sealMs ms), '
      'frame ${rate(frameMs == 0 ? 1 : frameMs)} MB/s ($frameMs ms), '
      'take ${rate(takeMs == 0 ? 1 : takeMs)} MB/s ($takeMs ms), '
      'take+open per chunk ${rate(perChunkMs)} MB/s '
      '($perChunkMs ms, $perChunkHops opens), '
      'take+open 1 MiB batches ${rate(batchedMs)} MB/s '
      '($batchedMs ms, $batchedHops opens)',
    );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
