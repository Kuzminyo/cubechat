import 'package:cubechat/core/transport/contact_card.dart';
import 'package:cubechat/features/backup/data/phone_transfer_socket_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';

void main() {
  group('contact card', () {
    final bytes = Uint8List.fromList(List.generate(120, (i) => i));

    test('is an https link a plain scanner can open', () {
      final card = ContactCard.encode(bytes);
      expect(card, startsWith('https://'));
      // The payload rides in the fragment, which browsers never send to the
      // host — that is the whole reason it is allowed to be a link at all.
      expect(card.contains('#'), isTrue);
      expect(card.indexOf('#') < card.indexOf(ContactCard.scheme), isTrue);
    });

    test('is still readable by a build that only knows the old token', () {
      // What the old reader does: find `cubechat:c1:` anywhere and take what
      // follows. One string therefore serves both.
      final card = ContactCard.encode(bytes);
      final at = card.indexOf(ContactCard.scheme);
      expect(at, greaterThan(0));
      final token = card.substring(at + ContactCard.scheme.length);
      expect(token, isNotEmpty);
      expect(ContactCard.tryDecodeBytes(card), bytes);
    });

    test('the bare old form still decodes', () {
      expect(
        ContactCard.tryDecodeBytes('${ContactCard.scheme}AAECAwQ'),
        isNotNull,
      );
    });
  });

  group('phone transfer', () {
    const payload = PhoneTransferPayload(
      host: '192.168.0.10',
      port: 4040,
      token: 'a-token-long-enough-to-pass',
      password: 'hunter2-and-then-some',
    );

    test('encodes as a link and decodes back', () {
      final encoded = payload.encode();
      expect(encoded, startsWith(PhoneTransferPayload.linkPrefix));

      final back = PhoneTransferPayload.tryDecode(encoded);
      expect(back, isNotNull);
      expect(back!.host, payload.host);
      expect(back.port, payload.port);
      expect(back.token, payload.token);
      expect(back.password, payload.password);
    });

    test('a scanner that hands back extra text is still understood', () {
      final noisy = '  ${payload.encode()}  ';
      expect(PhoneTransferPayload.tryDecode(noisy)?.host, payload.host);
    });

    test('the bare old form still decodes', () {
      final old = payload.encode().substring(
            PhoneTransferPayload.linkPrefix.length,
          );
      expect(old, startsWith(PhoneTransferPayload.prefix));
      expect(PhoneTransferPayload.tryDecode(old)?.port, payload.port);
    });

    test('something that is not ours is refused', () {
      expect(PhoneTransferPayload.tryDecode('https://example.com/hello'),
          isNull);
    });
  });
}
