import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/features/backup/data/desktop_link_service.dart';
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
      expect(text, startsWith('https://cubechat.app/l1#cubechat:l1:'));
      final back = DesktopLinkPayload.tryDecode(text)!;
      expect(back.host, '192.168.1.20');
      expect(back.port, 50123);
      expect(back.token, token);
      expect(back.password, password);
    });

    test('is not a phone-to-phone transfer code, nor garbage', () {
      expect(DesktopLinkPayload.tryDecode('cubechat:t1:eyJob3N0IjoxfQ'), isNull);
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

  group('the transfer', () {
    late List<({Uint8List bytes, String password})> restored;
    late DesktopLinkService computer;
    late DesktopLinkService phone;
    final backup = Uint8List.fromList(List.generate(300000, (i) => i % 251));

    setUp(() {
      restored = [];
      computer = DesktopLinkService(
        createBackup: (_) async => throw StateError('the computer only takes'),
        restoreBackup: (bytes, pw) async =>
            restored.add((bytes: bytes, password: pw)),
        localHost: () async => '127.0.0.1',
      );
      phone = DesktopLinkService(
        createBackup: (pw) async {
          expect(pw, isNotEmpty);
          return backup;
        },
        restoreBackup: (_, __) async => throw StateError('the phone only gives'),
        localHost: () async => '127.0.0.1',
      );
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

    test('a wrong token restores nothing and leaves the code usable',
        () async {
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
