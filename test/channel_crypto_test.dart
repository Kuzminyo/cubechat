import 'dart:convert';
import 'dart:typed_data';

import 'package:cubechat/core/crypto/channel_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChannelCrypto key/tag derivation', () {
    test('same name + password derive the same key', () async {
      final a = await ChannelCrypto.deriveKey('#general', 'hunter2');
      final b = await ChannelCrypto.deriveKey('#general', 'hunter2');
      expect(a, equals(b));
      expect(a.length, ChannelCrypto.keyLen);
    });

    test('different password derives a different key', () async {
      final a = await ChannelCrypto.deriveKey('#general', 'hunter2');
      final b = await ChannelCrypto.deriveKey('#general', 'other');
      expect(a, isNot(equals(b)));
    });

    test('different name derives a different key', () async {
      final a = await ChannelCrypto.deriveKey('#general', '');
      final b = await ChannelCrypto.deriveKey('#random', '');
      expect(a, isNot(equals(b)));
    });

    test('tag is 8 bytes and stable for a key', () async {
      final key = await ChannelCrypto.deriveKey('#general', '');
      final t1 = await ChannelCrypto.deriveTag(key);
      final t2 = await ChannelCrypto.deriveTag(key);
      expect(t1.length, ChannelCrypto.tagLen);
      expect(t1, equals(t2));
    });

    test('distinct channels get distinct tags', () async {
      final k1 = await ChannelCrypto.deriveKey('#a', '');
      final k2 = await ChannelCrypto.deriveKey('#b', '');
      final t1 = await ChannelCrypto.deriveTag(k1);
      final t2 = await ChannelCrypto.deriveTag(k2);
      expect(t1, isNot(equals(t2)));
    });
  });

  group('ChannelCrypto seal/open', () {
    test('round-trips a plaintext under the same key', () async {
      final key = await ChannelCrypto.deriveKey('#general', 'pw');
      final msg = Uint8List.fromList(utf8.encode('hello channel 🦊'));
      final blob = await ChannelCrypto.seal(key, msg);
      final back = await ChannelCrypto.open(key, blob);
      expect(back, equals(msg));
    });

    test('a wrong key fails the AEAD tag check', () async {
      final key = await ChannelCrypto.deriveKey('#general', 'pw');
      final wrong = await ChannelCrypto.deriveKey('#general', 'nope');
      final blob = await ChannelCrypto.seal(key, Uint8List.fromList([1, 2, 3]));
      expect(() => ChannelCrypto.open(wrong, blob), throwsA(anything));
    });

    test('two seals of the same message differ (random nonce)', () async {
      final key = await ChannelCrypto.deriveKey('#general', 'pw');
      final msg = Uint8List.fromList([9, 9, 9]);
      final a = await ChannelCrypto.seal(key, msg);
      final b = await ChannelCrypto.seal(key, msg);
      expect(a, isNot(equals(b)));
      expect(await ChannelCrypto.open(key, a), equals(msg));
      expect(await ChannelCrypto.open(key, b), equals(msg));
    });

    test('a truncated blob throws', () async {
      final key = await ChannelCrypto.deriveKey('#general', 'pw');
      expect(
        () => ChannelCrypto.open(key, Uint8List(4)),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
