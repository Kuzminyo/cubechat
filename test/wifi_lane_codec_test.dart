import 'dart:typed_data';

import 'package:cubechat/features/airdrop/data/wifi_lane_codec.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _key([int seed = 1]) =>
    Uint8List.fromList(List.generate(32, (i) => (i * 7 + seed) & 0xFF));

WifiRecord _data(int n, int fill) =>
    WifiRecord(WifiRecordKind.data, Uint8List(n)..fillRange(0, n, fill));

void main() {
  test('records round-trip in order, big ones through the isolate', () async {
    final tx = WifiLaneCipher(_key(), WifiDirection.toReceiver);
    final rx = WifiLaneCipher(_key(), WifiDirection.toReceiver);
    final records = [
      WifiRecord(WifiRecordKind.hello, Uint8List.fromList([1, 2, 3])),
      _data(WifiLaneCodec.dataBytes, 0xAB),
      _data(10, 0xCD),
      WifiRecord(WifiRecordKind.fileEnd, Uint8List(0)),
    ];
    final opened = await rx.open(await tx.seal(records));
    expect([for (final r in opened) r.kind], [for (final r in records) r.kind]);
    expect(opened[1].body, records[1].body);
    expect(opened[2].body, records[2].body);
  });

  test('a flipped byte is refused', () async {
    final tx = WifiLaneCipher(_key(), WifiDirection.toReceiver);
    final rx = WifiLaneCipher(_key(), WifiDirection.toReceiver);
    final sealed = await tx.seal([_data(100, 1)]);
    sealed[0][5] ^= 0x01;
    expect(rx.open(sealed), throwsA(isA<FormatException>()));
  });

  test('a record replayed out of order is refused', () async {
    final tx = WifiLaneCipher(_key(), WifiDirection.toReceiver);
    final rx = WifiLaneCipher(_key(), WifiDirection.toReceiver);
    final sealed = await tx.seal([_data(10, 1), _data(10, 2)]);
    expect(rx.open([sealed[1]]), throwsA(isA<FormatException>()));
  });

  test('the other direction cannot open it, nor a wrong key', () async {
    final sealed =
        await WifiLaneCipher(_key(), WifiDirection.toReceiver).seal([
      _data(10, 1),
    ]);
    expect(
      WifiLaneCipher(_key(), WifiDirection.toSender).open(sealed),
      throwsA(isA<FormatException>()),
    );
    expect(
      WifiLaneCipher(_key(2), WifiDirection.toReceiver).open(sealed),
      throwsA(isA<FormatException>()),
    );
  });

  test('the framer splits a byte stream cut anywhere', () {
    final a = Uint8List.fromList(List.generate(70, (i) => i));
    // A real sealed record is never shorter than its 16-byte tag plus the
    // kind byte, and the framer refuses one that is.
    final b = Uint8List.fromList(List.generate(20, (i) => 9));
    final stream = [...WifiLaneCodec.frame(a), ...WifiLaneCodec.frame(b)];
    final framer = WifiRecordFramer();
    final got = <Uint8List>[];
    for (var i = 0; i < stream.length; i += 5) {
      framer.add(
        Uint8List.fromList(
          stream.sublist(i, i + 5 > stream.length ? stream.length : i + 5),
        ),
      );
      got.addAll(framer.take());
    }
    expect(got, [a, b]);
  });

  test('the framer refuses an absurd length', () {
    final framer = WifiRecordFramer()
      ..add(Uint8List.fromList([0x7F, 0xFF, 0xFF, 0xFF, 0]));
    expect(framer.take, throwsFormatException);
  });
}
