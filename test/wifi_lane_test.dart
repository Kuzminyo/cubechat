import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/nearby_offer.dart';
import 'package:cubechat/features/airdrop/data/wifi_lane.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int n, [int seed = 0]) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 31 + seed) & 0xFF));

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('wifi-lane'));
  tearDown(() async => tmp.delete(recursive: true));

  final key = _bytes(32, 5);
  final tid = _bytes(16, 9);
  final loop = InternetAddress.loopbackIPv4;

  Future<File> source(String name, int size, int seed) async =>
      File('${tmp.path}/$name')..writeAsBytesSync(_bytes(size, seed));

  test('two files arrive whole, in order, and are kept', () async {
    final a = await source('a.bin', 200 * 1024 + 7, 1);
    final b = await source('b.bin', 10, 2);
    final kept = <String, Uint8List>{};
    final rxDir = await Directory('${tmp.path}/rx').create();
    final rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'aa' * 16: 200 * 1024 + 7, 'bb' * 16: 10},
      tempDir: rxDir,
      onProgress: (_, __, ___) {},
      onFile: (id, f) async {
        kept[id] = await f.readAsBytes();
        return true;
      },
    );
    final tx = await WifiLaneSender.connect(
      endpoint: NearbyWifiEndpoint(
        address: loop.address,
        port: rx.port,
        key: key,
      ),
      transferId: tid,
    );
    expect(tx, isNotNull);
    expect(
      await tx!.sendFile(
        mediaIdHex: 'aa' * 16,
        file: a,
        size: 200 * 1024 + 7,
        onProgress: (_, __, ___) {},
        cancelled: () => false,
      ),
      isTrue,
    );
    expect(
      await tx.sendFile(
        mediaIdHex: 'bb' * 16,
        file: b,
        size: 10,
        onProgress: (_, __, ___) {},
        cancelled: () => false,
      ),
      isTrue,
    );
    await rx.done.timeout(const Duration(seconds: 5));
    expect(kept['aa' * 16], await a.readAsBytes());
    expect(kept['bb' * 16], await b.readAsBytes());
    await tx.close();
  });

  test('a connection with the wrong key is dropped, the right one still gets in',
      () async {
    final rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'aa' * 16: 3},
      tempDir: tmp,
      onProgress: (_, __, ___) {},
      onFile: (_, __) async => true,
    );
    final intruder = await WifiLaneSender.connect(
      endpoint: NearbyWifiEndpoint(
        address: loop.address,
        port: rx.port,
        key: _bytes(32, 77),
      ),
      transferId: tid,
    );
    // The receiver refuses the hello and closes that socket; sending fails.
    final f = await source('x.bin', 3, 3);
    expect(
      await intruder?.sendFile(
            mediaIdHex: 'aa' * 16,
            file: f,
            size: 3,
            onProgress: (_, __, ___) {},
            cancelled: () => false,
          ) ??
          false,
      isFalse,
    );
    final real = await WifiLaneSender.connect(
      endpoint: NearbyWifiEndpoint(
        address: loop.address,
        port: rx.port,
        key: key,
      ),
      transferId: tid,
    );
    expect(
      await real!.sendFile(
        mediaIdHex: 'aa' * 16,
        file: f,
        size: 3,
        onProgress: (_, __, ___) {},
        cancelled: () => false,
      ),
      isTrue,
    );
    await real.close();
    await rx.close();
  });

  test('a file that is not the size offered is refused', () async {
    final rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'aa' * 16: 5},
      tempDir: tmp,
      onProgress: (_, __, ___) {},
      onFile: (_, __) async => true,
    );
    final tx = await WifiLaneSender.connect(
      endpoint:
          NearbyWifiEndpoint(address: loop.address, port: rx.port, key: key),
      transferId: tid,
    );
    final f = await source('y.bin', 9, 1);
    expect(
      await tx!.sendFile(
        mediaIdHex: 'aa' * 16,
        file: f,
        size: 9,
        onProgress: (_, __, ___) {},
        cancelled: () => false,
      ),
      isFalse,
    );
    await tx.close();
    await rx.close();
  });

  test('nobody listening: connect gives up within the timeout', () async {
    final free = await ServerSocket.bind(loop, 0);
    final port = free.port;
    await free.close();
    final sw = Stopwatch()..start();
    final tx = await WifiLaneSender.connect(
      endpoint: NearbyWifiEndpoint(address: loop.address, port: port, key: key),
      transferId: tid,
      timeout: const Duration(seconds: 1),
    );
    expect(tx, isNull);
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('cancelling mid-file stops and reports false', () async {
    final rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'aa' * 16: 3 * 1024 * 1024},
      tempDir: tmp,
      onProgress: (_, __, ___) {},
      onFile: (_, __) async => true,
    );
    final tx = await WifiLaneSender.connect(
      endpoint:
          NearbyWifiEndpoint(address: loop.address, port: rx.port, key: key),
      transferId: tid,
    );
    final f = await source('big.bin', 3 * 1024 * 1024, 4);
    var calls = 0;
    expect(
      await tx!.sendFile(
        mediaIdHex: 'aa' * 16,
        file: f,
        size: 3 * 1024 * 1024,
        onProgress: (_, __, ___) {},
        cancelled: () => ++calls > 1,
      ),
      isFalse,
    );
    await tx.close();
    await rx.close();
  });

  test('the receiver closes itself after the idle time', () async {
    final rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'aa' * 16: 3},
      tempDir: tmp,
      onProgress: (_, __, ___) {},
      onFile: (_, __) async => true,
      idle: const Duration(milliseconds: 300),
    );
    await rx.done.timeout(const Duration(seconds: 3));
    await expectLater(
      Socket.connect(loop, rx.port, timeout: const Duration(seconds: 1)),
      throwsA(isA<SocketException>()),
    );
  });

  test(
      'onFile throwing does not wedge the receiver: sendFile fails promptly and done completes',
      () async {
    final rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'aa' * 16: 5},
      tempDir: tmp,
      onProgress: (_, __, ___) {},
      onFile: (_, __) async => throw Exception('boom'),
    );
    final tx = await WifiLaneSender.connect(
      endpoint:
          NearbyWifiEndpoint(address: loop.address, port: rx.port, key: key),
      transferId: tid,
    );
    final f = await source('z.bin', 5, 6);
    final sw = Stopwatch()..start();
    final ok = await tx!
        .sendFile(
          mediaIdHex: 'aa' * 16,
          file: f,
          size: 5,
          onProgress: (_, __, ___) {},
          cancelled: () => false,
        )
        .timeout(const Duration(seconds: 5));
    expect(ok, isFalse);
    // "Promptly" means nowhere near the 2-minute idle close this receiver
    // was given by default — a wedged queue used to make the sender sit in
    // flush() until that timer finally gave up on it.
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    await rx.done.timeout(const Duration(seconds: 5));
    await tx.close();
  });

  test(
      'close() during a large transfer leaves no leftover part file and never calls onFile',
      () async {
    final rxDir = await Directory('${tmp.path}/rx3').create();
    var onFileCalled = false;
    final firstProgress = Completer<void>();
    final rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'aa' * 16: 3 * 1024 * 1024},
      tempDir: rxDir,
      onProgress: (_, __, ___) {
        if (!firstProgress.isCompleted) firstProgress.complete();
      },
      onFile: (_, __) async {
        onFileCalled = true;
        return true;
      },
    );
    final tx = await WifiLaneSender.connect(
      endpoint:
          NearbyWifiEndpoint(address: loop.address, port: rx.port, key: key),
      transferId: tid,
    );
    final f = await source('big2.bin', 3 * 1024 * 1024, 8);
    // Deliberately not awaited here — the point is to close the receiver
    // while a batch is still mid-write, not after the transfer finishes.
    final sendDone = tx!.sendFile(
      mediaIdHex: 'aa' * 16,
      file: f,
      size: 3 * 1024 * 1024,
      onProgress: (_, __, ___) {},
      cancelled: () => false,
    );
    await firstProgress.future.timeout(const Duration(seconds: 5));
    await rx.close();
    expect(await sendDone.timeout(const Duration(seconds: 5)), isFalse);
    await tx.close();
    expect(onFileCalled, isFalse);
    expect(
      rxDir.listSync().where((e) => e.path.endsWith('.part')),
      isEmpty,
    );
  });

  group('pickLanAddress', () {
    InternetAddress ip(String s) => InternetAddress(s);
    test('Wi-Fi over cellular, private IPv4 first', () {
      expect(
        pickLanAddress([
          (name: 'rmnet_data0', address: ip('10.77.1.2')),
          (name: 'wlan0', address: ip('fe80::1')),
          (name: 'wlan0', address: ip('192.168.1.23')),
        ])?.address,
        '192.168.1.23',
      );
    });
    test('a phone sharing its hotspot offers the hotspot address', () {
      expect(
        pickLanAddress([
          (name: 'pdp_ip0', address: ip('100.64.0.5')),
          (name: 'bridge100', address: ip('172.20.10.1')),
        ])?.address,
        '172.20.10.1',
      );
    });
    test('nothing but cellular and link-local: null', () {
      expect(
        pickLanAddress([
          (name: 'ccmni0', address: ip('10.1.1.1')),
          (name: 'wlan0', address: ip('169.254.3.3')),
        ]),
        isNull,
      );
    });
  });
}
