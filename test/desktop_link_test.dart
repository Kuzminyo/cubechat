import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cubechat/features/backup/data/desktop_link_service.dart';
import 'package:cubechat/features/backup/data/phone_transfer_socket_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Sign in with my phone's account" on a computer: the computer serves and
/// shows a code, the phone pushes an encrypted copy of itself to it — the
/// reverse of moving between phones, because a computer seldom has a camera.
void main() {
  const token = 'tttttttttttttttttttttttttttttttt';
  const password = 'pppppppppppppppppppppppppppppppp';

  group('the code', () {
    test('round-trips and travels inside an https link', () {
      const p = DesktopLinkPayload(
        host: '192.168.1.20',
        port: 50123,
        token: token,
        password: password,
      );
      final text = p.encode();
      expect(text, startsWith('https://cubechat.tech/l1#cubechat:l1:'));
      final back = DesktopLinkPayload.tryDecode(text)!;
      expect(back.host, '192.168.1.20');
      expect(back.port, 50123);
      expect(back.token, token);
      expect(back.password, password);
    });

    test('is not a phone-to-phone transfer code, nor garbage', () {
      expect(
        DesktopLinkPayload.tryDecode('cubechat:t1:eyJob3N0IjoxfQ'),
        isNull,
      );
      expect(DesktopLinkPayload.tryDecode('cubechat:l1:!!!'), isNull);
      expect(DesktopLinkPayload.tryDecode('hello'), isNull);
      const short = DesktopLinkPayload(
        host: 'h',
        port: 1,
        token: 'short',
        password: password,
      );
      expect(DesktopLinkPayload.tryDecode(short.encode()), isNull);
    });
  });

  group('which address the code names', () {
    // This computer, 2026-10-11: Wi-Fi 192.168.0.134 beside VirtualBox
    // 192.168.56.1, Hyper-V 172.21.32.1 and WSL 172.27.64.1. The old code took
    // the first private address the system listed — 192.168.56.1 — and the QR
    // pointed the phone at a card it could never reach.
    const adapters = [
      (name: 'Ethernet 2', address: '192.168.56.1'),
      (name: 'Беспроводная сеть', address: '192.168.0.134'),
      (name: 'vEthernet (Default Switch)', address: '172.21.32.1'),
      (name: 'vEthernet (WSL (Hyper-V firewall))', address: '172.27.64.1'),
    ];

    test('the real network comes first, virtual adapters last', () {
      final ordered = orderLocalAddresses(adapters);
      expect(ordered.first, '192.168.0.134');
      expect(ordered.toSet(), {
        '192.168.0.134',
        '192.168.56.1',
        '172.21.32.1',
        '172.27.64.1',
      }, reason: 'none dropped: an unlabelled adapter may be the real one');
      expect(ordered.last, anyOf('172.21.32.1', '172.27.64.1'));
    });

    test('only private addresses are ever offered', () {
      expect(
        orderLocalAddresses(const [
          (name: 'wlan0', address: '8.8.8.8'),
          (name: 'wlan1', address: '192.168.1.5'),
        ]),
        ['192.168.1.5'],
      );
    });

    test('a code carries every candidate, and an old code just the one', () {
      const p = DesktopLinkPayload(
        host: '192.168.0.134',
        port: 50123,
        token: token,
        password: password,
        hosts: ['192.168.0.134', '192.168.56.1'],
      );
      final back = DesktopLinkPayload.tryDecode(p.encode())!;
      expect(back.candidates, ['192.168.0.134', '192.168.56.1']);
      const old = DesktopLinkPayload(
        host: '10.0.0.4',
        port: 1,
        token: token,
        password: password,
      );
      expect(DesktopLinkPayload.tryDecode(old.encode())!.candidates,
          ['10.0.0.4']);
    });

    test('a candidate off the local network spoils the whole code', () {
      const p = DesktopLinkPayload(
        host: '192.168.0.134',
        port: 50123,
        token: token,
        password: password,
        hosts: ['192.168.0.134', '8.8.8.8'],
      );
      expect(DesktopLinkPayload.tryDecode(p.encode()), isNull);
    });
  });

  test('a code naming a host outside the local network is refused', () {
    // The code says where to send the account. A link on a web page or in a
    // chat can carry any address, and "Send?" is one tap: without this a
    // stranger's server could be handed the keys. Only the local network is
    // ever the other end of a transfer — both devices on one Wi-Fi.
    DesktopLinkPayload at(String host) => DesktopLinkPayload(
          host: host,
          port: 4000,
          token: token,
          password: password,
        );
    for (final ok in ['192.168.0.7', '10.1.2.3', '172.16.0.1', '172.31.9.9',
        '169.254.10.20', '127.0.0.1']) {
      expect(DesktopLinkPayload.tryDecode(at(ok).encode()), isNotNull, reason: ok);
    }
    for (final bad in ['8.8.8.8', '172.32.0.1', '172.15.0.1', '203.0.113.5',
        'evil.example', '192.168.0.7.evil.example', '', '::1']) {
      expect(DesktopLinkPayload.tryDecode(at(bad).encode()), isNull, reason: bad);
    }
  });

  test('a transfer or sign-in link, new or old, is opened into the scanner',
      () {
    const code = DesktopLinkPayload(
      host: '10.0.0.2',
      port: 4000,
      token: token,
      password: password,
    );
    expect(isTransferLink(Uri.parse(code.encode())), isTrue);
    expect(
      isTransferLink(Uri.parse('https://cubechat.app/t1#cubechat:t1:abc')),
      isTrue,
      reason: 'codes printed before the move to cubechat.tech',
    );
    expect(
      isTransferLink(Uri.parse('https://cubechat.tech/c1#cubechat:c1:abc')),
      isFalse,
      reason: 'a contact card stays a contact card',
    );
  });

  group('the transfer', () {
    late List<({Uint8List bytes, String password})> restored;
    late DesktopLinkService computer;
    late DesktopLinkService phone;
    late Directory temp;
    // Many socket chunks long, so the copy is reassembled from a stream.
    final backup = Uint8List.fromList(List.generate(3000000, (i) => i % 251));
    var n = 0;

    setUp(() async {
      restored = [];
      temp = await Directory.systemTemp.createTemp('cubechat_link_');
      Future<File> tempFile(String role) async =>
          File('${temp.path}/${role}_${n++}.bin');
      computer = DesktopLinkService(
        createBackup: (_, __) async =>
            throw StateError('the computer only takes'),
        restoreBackup: (file, pw) async =>
            restored.add((bytes: await file.readAsBytes(), password: pw)),
        localHosts: () async => ['127.0.0.1'],
        tempFile: tempFile,
      );
      phone = DesktopLinkService(
        createBackup: (file, pw) async {
          expect(pw, isNotEmpty);
          await file.writeAsBytes(backup);
        },
        restoreBackup: (_, __) async =>
            throw StateError('the phone only gives'),
        localHosts: () async => ['127.0.0.1'],
        tempFile: tempFile,
      );
    });

    tearDown(() async {
      try {
        await temp.delete(recursive: true);
      } on FileSystemException {
        // Windows may still hold a file for a moment.
      }
    });

    test('a dead first address does not stop the copy reaching a live one',
        () async {
      final session = await computer.startReceiving();
      final code = DesktopLinkPayload.tryDecode(session.qr)!;
      // First an address nothing answers on (unroutable, so the connect would
      // sit there until its timeout), then the one that works.
      final aimed = DesktopLinkPayload(
        host: '10.255.255.1',
        port: code.port,
        token: code.token,
        password: code.password,
        hosts: const ['10.255.255.1', '127.0.0.1'],
      );
      await phone.sendTo(aimed).timeout(const Duration(seconds: 8));
      await session.done;
      expect(restored.single.bytes, backup);
    });

    test('the phone\'s copy arrives whole, under the code\'s password',
        () async {
      final session = await computer.startReceiving();
      final code = DesktopLinkPayload.tryDecode(session.qr)!;
      await phone.sendTo(code);
      await session.done;
      expect(restored, hasLength(1));
      expect(restored.single.bytes, backup);
      expect(restored.single.password, code.password);
    });

    test('a wrong token restores nothing and leaves the code usable', () async {
      final session = await computer.startReceiving();
      final code = DesktopLinkPayload.tryDecode(session.qr)!;
      final forged = DesktopLinkPayload(
        host: code.host,
        port: code.port,
        token: 'x' * code.token.length,
        password: code.password,
      );
      await expectLater(phone.sendTo(forged), throwsA(anything));
      expect(restored, isEmpty);
      await phone.sendTo(code);
      await session.done;
      expect(restored, hasLength(1));
    });

    test('the code works once', () async {
      final session = await computer.startReceiving();
      final code = DesktopLinkPayload.tryDecode(session.qr)!;
      await phone.sendTo(code);
      await session.done;
      await expectLater(phone.sendTo(code), throwsA(anything));
      expect(restored, hasLength(1));
    });

    test('an authenticated truncated stream finishes with an error', () async {
      final session = await computer.startReceiving();
      final failure =
          expectLater(session.done, throwsA(isA<FormatException>()));
      final code = DesktopLinkPayload.tryDecode(session.qr)!;
      final socket = await Socket.connect(code.host, code.port);
      socket.add(ascii.encode(code.token));
      socket.add((ByteData(8)..setUint64(0, 1024)).buffer.asUint8List());
      socket.add([1, 2, 3]);
      await socket.flush();
      await socket.close();
      await failure.timeout(const Duration(seconds: 5));
      socket.destroy();
      expect(restored, isEmpty);
    });

    test('a backup larger than 48 MB streams to the computer', () async {
      const size = 49 * 1024 * 1024;
      final sender = DesktopLinkService(
        tempFile: (role) async => File('${temp.path}/large-$role'),
        createBackup: (file, _) async {
          final out = await file.open(mode: FileMode.write);
          await out.truncate(size);
          await out.setPosition(size - 1);
          await out.writeByte(71);
          await out.close();
        },
        restoreBackup: (_, __) async {},
      );
      final receiver = DesktopLinkService(
        localHosts: () async => ['127.0.0.1'],
        tempFile: (role) async => File('${temp.path}/large-$role'),
        createBackup: (_, __) async {},
        restoreBackup: (file, _) async {
          expect(await file.length(), size);
          expect(await file.openRead(size - 1).first, [71]);
        },
      );
      final session = await receiver.startReceiving();
      await sender.sendTo(DesktopLinkPayload.tryDecode(session.qr)!);
      await session.done;
    });

    test('nobody listening is an error within seconds, not a hang', () async {
      final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = free.port;
      await free.close();
      final dead = DesktopLinkPayload(
        host: '127.0.0.1',
        port: port,
        token: token,
        password: password,
      );
      await expectLater(
        phone.sendTo(dead).timeout(const Duration(seconds: 15)),
        throwsA(isNot(isA<TimeoutException>())),
      );
    });
  });
}
