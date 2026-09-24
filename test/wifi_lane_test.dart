import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/nearby_offer.dart';
import 'package:cubechat/features/airdrop/data/wifi_lane.dart';
import 'package:cubechat/features/airdrop/data/wifi_lane_codec.dart';
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

  test('a big file is opened in batches of about 1 MiB, still in order',
      () async {
    const size = 8 * 1024 * 1024 + 123;
    final a = await source('big.bin', size, 3);
    Uint8List? got;
    final rxDir = await Directory('${tmp.path}/rx').create();
    final rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'cc' * 16: size},
      tempDir: rxDir,
      onProgress: (_, __, ___) {},
      onFile: (id, f) async {
        got = await f.readAsBytes();
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
    expect(
      await tx!.sendFile(
        mediaIdHex: 'cc' * 16,
        file: a,
        size: size,
        onProgress: (_, __, ___) {},
        cancelled: () => false,
      ),
      isTrue,
    );
    await tx.close();
    await rx.done.timeout(const Duration(seconds: 10));
    expect(got, await a.readAsBytes());
    // 129 records of 64 KiB. Opened one TCP read at a time that was well
    // over a hundred isolate hops; in 1 MiB batches it is about nine, plus
    // the odd short batch for hello and fileEnd.
    expect(rx.debugOpenBatches, lessThanOrEqualTo(20));
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

  test('closed mid-file: stops reading at once and reports false', () async {
    const size = 8 * 1024 * 1024;
    final rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'aa' * 16: size},
      tempDir: tmp,
      onProgress: (_, __, ___) {},
      onFile: (_, __) async => true,
    );
    final tx = await WifiLaneSender.connect(
      endpoint:
          NearbyWifiEndpoint(address: loop.address, port: rx.port, key: key),
      transferId: tid,
    );
    final f = await source('huge.bin', size, 6);
    final reported = <int>[];
    // What the controller's watchdog does: close from outside while the
    // loop is running. A destroyed socket still takes add() and flush()
    // without complaint, so only the loop's own check can stop it.
    final ok = await tx!.sendFile(
      mediaIdHex: 'aa' * 16,
      file: f,
      size: size,
      onProgress: (_, done, __) {
        reported.add(done);
        if (reported.length == 1) unawaited(tx.close());
      },
      cancelled: () => false,
    );
    expect(ok, isFalse);
    expect(reported, hasLength(1));
    expect(reported.last, lessThan(size));
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

  test(
      'close() called from onProgress mid-file leaves no leftover part file and never calls onFile',
      () async {
    final rxDir = await Directory('${tmp.path}/rx4').create();
    var onFileCalled = false;
    var closedOnce = false;
    late final WifiLaneReceiver rx;
    rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'aa' * 16: 3 * 1024 * 1024},
      tempDir: rxDir,
      onProgress: (_, __, ___) {
        if (closedOnce) return;
        closedOnce = true;
        // Fires synchronously from inside the very batch that just
        // completed `await raf.writeFrom(...)` for this data record — the
        // exact window the queue-tail fix in close() targets, without
        // depending on any real-time delay to land inside it. Not awaited:
        // the app is entitled to call close() from a progress callback
        // without knowing it must not block on the result.
        unawaited(rx.close());
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
    final f = await source('big3.bin', 3 * 1024 * 1024, 9);
    final ok = await tx!
        .sendFile(
          mediaIdHex: 'aa' * 16,
          file: f,
          size: 3 * 1024 * 1024,
          onProgress: (_, __, ___) {},
          cancelled: () => false,
        )
        .timeout(const Duration(seconds: 5));
    expect(ok, isFalse);
    await tx.close();
    // The close above was not awaited, and the sender now gives up the
    // moment its read side reports the hang-up — before the receiver has
    // finished sweeping. `done` completes only after that sweep.
    await rx.done.timeout(const Duration(seconds: 5));
    expect(onFileCalled, isFalse);
    expect(
      rxDir.listSync().where((e) => e.path.endsWith('.part')),
      isEmpty,
    );
  });

  test(
      'the receiver hanging up between two slices still ends sendFile '
      '(the socket errors while the next slice is being sealed)', () async {
    // What CI hit after 2268cbcc: the receiver closes once a whole 1 MiB
    // batch has landed, which is exactly when the sender is reading and
    // sealing its next slice. The reset lands in that gap, dart:io marks the
    // native socket closing, and the next add() + flush() never completes —
    // a closing socket takes 0 bytes and never raises a write event. Made
    // deterministic here: the peer is gone before slice two is written, so
    // writing it draws a reset, and the sender sleeps at the top of slice
    // three until that reset has certainly arrived.
    final server = await ServerSocket.bind(loop, 0);
    final accepted = Completer<Socket>();
    server.listen((s) {
      s.listen((_) {}, onError: (Object _) {}, cancelOnError: true);
      accepted.complete(s);
    });
    final tx = await WifiLaneSender.connect(
      endpoint:
          NearbyWifiEndpoint(address: loop.address, port: server.port, key: key),
      transferId: tid,
    );
    final peer = await accepted.future;
    const size = 3 * 1024 * 1024 + 1;
    final f = File('${tmp.path}/reset.bin')..writeAsBytesSync(Uint8List(size));
    var calls = 0;
    final ok = await tx!
        .sendFile(
          mediaIdHex: 'aa' * 16,
          file: f,
          size: size,
          onProgress: (_, __, ___) {},
          cancelled: () {
            calls++;
            if (calls == 2) {
              peer.destroy();
              sleep(const Duration(milliseconds: 200));
            } else if (calls == 3) {
              sleep(const Duration(milliseconds: 300));
            }
            return false;
          },
        )
        .timeout(const Duration(seconds: 5));
    expect(ok, isFalse);
    await tx.close();
    await server.close();
  });

  test(
      'closing the sender while its flush waits on a receiver that stopped '
      'reading ends sendFile', () async {
    // The controller's stall watchdog closes a sender whose receiver went
    // quiet — which is precisely when a flush is parked on a full socket
    // buffer. destroy() stops the socket's writer without completing that
    // flush, so without a bound of its own sendFile waited forever.
    final server = await ServerSocket.bind(loop, 0);
    final accepted = Completer<Socket>();
    server.listen((s) {
      // Never read: the sender's buffers fill and its flush parks.
      s.listen((_) {}, onError: (Object _) {}, cancelOnError: true).pause();
      accepted.complete(s);
    });
    final tx = await WifiLaneSender.connect(
      endpoint:
          NearbyWifiEndpoint(address: loop.address, port: server.port, key: key),
      transferId: tid,
    );
    final peer = await accepted.future;
    const size = 64 * 1024 * 1024;
    final f = File('${tmp.path}/stall.bin')..writeAsBytesSync(Uint8List(size));
    Timer? watchdog;
    void arm() {
      watchdog?.cancel();
      watchdog = Timer(const Duration(milliseconds: 500), () => tx!.close());
    }

    arm();
    final ok = await tx!
        .sendFile(
          mediaIdHex: 'aa' * 16,
          file: f,
          size: size,
          onProgress: (_, __, ___) => arm(),
          cancelled: () => false,
        )
        .timeout(const Duration(seconds: 20));
    watchdog?.cancel();
    expect(ok, isFalse);
    peer.destroy();
    await server.close();
  });

  test(
      'close() while a partial batch waits out the quiet timer completes and '
      'leaves nothing behind', () async {
    // A lone fileStart and one short data record sit in the pending batch
    // for _openQuiet; close() lands inside that window. The pending batch
    // must simply be dropped — nothing may wait on it being opened.
    final rxDir = await Directory('${tmp.path}/rx5').create();
    var onFileCalled = false;
    final connected = Completer<void>();
    final rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'aa' * 16: 1024 * 1024},
      tempDir: rxDir,
      onProgress: (_, __, ___) {},
      onFile: (_, __) async {
        onFileCalled = true;
        return true;
      },
      onConnected: connected.complete,
    );
    final raw = await Socket.connect(loop, rx.port);
    final seal = WifiLaneCipher(key, WifiDirection.toReceiver);
    for (final s in await seal.seal([WifiRecord(WifiRecordKind.hello, tid)])) {
      raw.add(WifiLaneCodec.frame(s));
    }
    await raw.flush();
    await connected.future.timeout(const Duration(seconds: 5));
    final start = Uint8List(24)..setRange(0, 16, nearbyUnhex('aa' * 16));
    ByteData.sublistView(start).setUint64(16, 1024 * 1024);
    for (final s in await seal.seal([
      WifiRecord(WifiRecordKind.fileStart, start),
      WifiRecord(WifiRecordKind.data, Uint8List(1000)),
    ])) {
      raw.add(WifiLaneCodec.frame(s));
    }
    await raw.flush();
    // Well inside the 15 ms quiet window on any machine that delivered the
    // bytes at all; the batch is still waiting, not yet queued.
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await rx.close().timeout(const Duration(seconds: 5));
    await rx.done.timeout(const Duration(seconds: 1));
    // The quiet timer still fires after close and must find nothing to do.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(onFileCalled, isFalse);
    expect(
      rxDir.listSync().where((e) => e.path.endsWith('.part')),
      isEmpty,
    );
    raw.destroy();
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

  group('lanEndpointAllowed', () {
    test('private IPv4 ranges are dialled', () {
      for (final a in [
        '10.0.0.7',
        '172.16.4.2',
        '172.31.255.1',
        '192.168.1.7',
      ]) {
        expect(lanEndpointAllowed(a), isTrue, reason: a);
      }
    });

    test('public, loopback, multicast, broadcast, unspecified and link-local '
        'are not', () {
      for (final a in [
        '8.8.8.8',
        '172.32.0.1',
        '127.0.0.1',
        '0.0.0.0',
        '224.0.0.251',
        '255.255.255.255',
        '169.254.1.1',
        '::1',
        '::',
        'ff02::1',
        'fe80::1',
        '2001:db8::1',
        '::ffff:192.168.1.7',
        'not an address',
        'localhost',
      ]) {
        expect(lanEndpointAllowed(a), isFalse, reason: a);
      }
    });

    test('an IPv6 unique-local address is dialled', () {
      expect(lanEndpointAllowed('fd12:3456:789a::1'), isTrue);
    });

    test('carrier NAT space only on our own subnet', () {
      expect(lanEndpointAllowed('100.64.3.9'), isFalse);
      expect(
        lanEndpointAllowed('100.64.3.9', own: InternetAddress('100.64.3.1')),
        isTrue,
      );
      expect(
        lanEndpointAllowed('100.64.3.9', own: InternetAddress('100.64.7.1')),
        isFalse,
      );
      expect(
        lanEndpointAllowed('100.64.3.9', own: InternetAddress('192.168.1.2')),
        isFalse,
      );
    });
  });
}
