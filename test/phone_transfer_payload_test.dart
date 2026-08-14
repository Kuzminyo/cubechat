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

  test('unrelated and incomplete transfer payloads are ignored', () {
    expect(PhoneTransferPayload.tryDecode('https://example.com'), isNull);
    expect(PhoneTransferPayload.tryDecode('${PhoneTransferPayload.prefix}e30'),
        isNull);
  });
}
