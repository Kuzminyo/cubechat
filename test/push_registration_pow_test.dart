import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:cubechat/core/notifications/push_registration.dart';
import 'package:cubechat/core/transport/nostr/nostr_event.dart';
import 'package:cubechat/core/transport/nostr/nostr_pow.dart';
import 'package:cubechat/core/transport/nostr/nostr_signer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a mined registration keeps its tags, in order, and signs', () async {
    final signer = await Secp256k1NostrSigner.deriveFromSeed(
      Uint8List.fromList(List<int>.filled(32, 9)),
    );
    final unsigned = NostrEvent(
      pubkey: signer.npubHex,
      createdAt: 1790000000,
      kind: PushRegistration.registrationKind,
      tags: const [
        ['lang', 'uk'],
        ['platform', 'android'],
      ],
      content: 'f' * 140,
    );

    final event = await signer.sign(await minePushRegistration(unsigned, 10));

    // The server reads lang and platform by name, so the shape the old
    // builds send stays exactly as it was — the nonce only joins at the end.
    expect(event.tags.take(2), unsigned.tags);
    expect(event.tags.last.take(1), ['nonce']);
    expect(event.tags.last.last, '10');
    expect(event.tags, hasLength(3));
    expect(event.content, unsigned.content);
    expect(event.createdAt, unsigned.createdAt);
    expect(await event.hasValidId(), isTrue);
    final digest =
        const DartSha256().hashSync(utf8.encode(event.serializeForId())).bytes;
    expect(leadingZeroBits(digest), greaterThanOrEqualTo(10));
  });

  group('powBitsAsked', () {
    test('reads the bits a pow refusal names', () {
      expect(
        PushRegistration.powBitsAsked(
          '{"ok":false,"reason":"pow","bits":16,"status":403}',
        ),
        16,
      );
    });

    test('bounds what the server may ask of the battery', () {
      expect(
        PushRegistration.powBitsAsked('{"ok":false,"reason":"pow","bits":40}'),
        PushRegistration.powMaxBits,
      );
      expect(
        PushRegistration.powBitsAsked('{"ok":false,"reason":"pow"}'),
        PushRegistration.powBits,
      );
    });

    test('is null for every other answer', () {
      expect(PushRegistration.powBitsAsked('{"ok":true}'), isNull);
      expect(
        PushRegistration.powBitsAsked('{"ok":false,"reason":"rate"}'),
        isNull,
      );
      expect(PushRegistration.powBitsAsked('<html>502</html>'), isNull);
      expect(PushRegistration.powBitsAsked('[1]'), isNull);
    });
  });
}
