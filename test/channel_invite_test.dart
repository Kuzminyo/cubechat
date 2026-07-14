import 'dart:convert';
import 'dart:typed_data';

import 'package:cubechat/core/crypto/sealed_box.dart';
import 'package:cubechat/core/crypto/signed_payload.dart';
import 'package:cubechat/core/transport/envelope.dart';
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List key(int seed) =>
      Uint8List.fromList(List.generate(32, (i) => (i + seed) & 0xff));

  group('ChannelInvite', () {
    test('encode/decode round-trips name and key', () {
      final invite = ChannelInvite(name: '#general', key: key(3));
      final back = ChannelInvite.decode(invite.encode());
      expect(back.name, '#general');
      expect(back.key, equals(key(3)));
    });

    test('rides through the inner-payload tag', () {
      final invite = ChannelInvite(name: '#ops', key: key(1));
      final wire =
          packInnerPayload(InnerPayloadType.channelInvite, invite.encode());
      final unpacked = unpackInnerPayload(wire);
      expect(unpacked.type, InnerPayloadType.channelInvite);
      expect(ChannelInvite.decode(unpacked.body).name, '#ops');
    });

    test('a multibyte name round-trips', () {
      // 10 bytes: '#' + 4 Cyrillic letters at 2 bytes each, plus one ASCII.
      const name = '#рейв1';
      expect(utf8.encode(name).length, lessThanOrEqualTo(
          ChannelInvite.maxNameBytes));
      final back = ChannelInvite.decode(
        ChannelInvite(name: name, key: key(7)).encode(),
      );
      expect(back.name, name);
    });

    test('a name at exactly maxNameBytes still encodes', () {
      final name = '#${'a' * (ChannelInvite.maxNameBytes - 1)}';
      expect(utf8.encode(name).length, ChannelInvite.maxNameBytes);
      expect(ChannelInvite.decode(
              ChannelInvite(name: name, key: key(0)).encode()).name,
          name);
    });

    test('a name one byte over the cap is rejected', () {
      final name = '#${'a' * ChannelInvite.maxNameBytes}';
      expect(
        () => ChannelInvite(name: name, key: key(0)).encode(),
        throwsA(isA<FormatException>()),
      );
    });

    test('an empty name is rejected', () {
      expect(
        () => ChannelInvite(name: '', key: key(0)).encode(),
        throwsA(isA<FormatException>()),
      );
    });

    test('a wrong-length key fails the assertion', () {
      expect(
        () => ChannelInvite(name: '#x', key: Uint8List(16)),
        throwsA(isA<AssertionError>()),
      );
    });

    test('a body with no room for a name is truncated', () {
      // Exactly the key, no name bytes left over.
      expect(
        () => ChannelInvite.decode(Uint8List(ChannelInvite.keyLen)),
        throwsA(isA<FormatException>()),
      );
    });

    test('decode rejects an over-long name a peer could hand-craft', () {
      final oversized =
          Uint8List(ChannelInvite.maxNameBytes + 1 + ChannelInvite.keyLen);
      expect(
        () => ChannelInvite.decode(oversized),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ChannelInvite single-frame budget', () {
    // Nothing below the invite reassembles fragments, so a maximal invite must
    // fit one BLE write. This pins maxNameBytes to the layers it's derived
    // from: if any header grows, this fails instead of silently producing
    // undeliverable invites.
    const frameTypeByte = 1;
    const cipherTagByte = 1;
    const innerTypeByte = 1;
    const frameCeiling = 240;

    int wireSizeFor(int nameBytes) =>
        frameTypeByte +
        TransportEnvelope.headerLen +
        cipherTagByte +
        SealedBox.overhead +
        SignedPayload.headerLen +
        innerTypeByte +
        nameBytes +
        ChannelInvite.keyLen;

    test('a maximal invite fits the conservative frame ceiling', () {
      expect(wireSizeFor(ChannelInvite.maxNameBytes),
          lessThanOrEqualTo(frameCeiling));
    });

    test('maxNameBytes is the largest name that fits — one more overflows', () {
      expect(wireSizeFor(ChannelInvite.maxNameBytes + 1),
          greaterThan(frameCeiling));
    });
  });
}
