import 'package:cubechat/features/backup/data/phone_transfer_socket_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('phone transfer QR payload round-trips one-use connection data', () {
    const payload = PhoneTransferPayload(
      host: '192.168.1.42',
      port: 43117,
      token: 'abcdefghijklmnopqrstuvwxyz123456',
      password: '0123456789abcdefghijklmnopqrstuvwxyzABCDEF',
    );

    final encoded = payload.encode();
    final decoded = PhoneTransferPayload.tryDecode(encoded);

    expect(encoded, startsWith(PhoneTransferPayload.linkPrefix));
    expect(encoded, contains(PhoneTransferPayload.prefix));
    expect(decoded?.host, payload.host);
    expect(decoded?.port, payload.port);
    expect(decoded?.token, payload.token);
    expect(decoded?.password, payload.password);
  });

  test('a code that points off the local network is refused', () {
    // Receiving restores whatever the other end sends over this account; a
    // link on a web page must not be able to aim that at a stranger's server.
    PhoneTransferPayload at(String host) => PhoneTransferPayload(
          host: host,
          port: 43117,
          token: 'abcdefghijklmnopqrstuvwxyz123456',
          password: '0123456789abcdefghijklmnopqrstuvwxyzABCDEF',
        );
    expect(PhoneTransferPayload.tryDecode(at('192.168.1.42').encode()),
        isNotNull);
    for (final bad in ['8.8.8.8', 'evil.example', '172.32.0.1', '']) {
      expect(PhoneTransferPayload.tryDecode(at(bad).encode()), isNull,
          reason: bad);
    }
  });

  test('unrelated and incomplete transfer payloads are ignored', () {
    expect(PhoneTransferPayload.tryDecode('https://example.com'), isNull);
    expect(PhoneTransferPayload.tryDecode('${PhoneTransferPayload.prefix}e30'),
        isNull);
  });
}
