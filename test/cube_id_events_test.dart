import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:cubechat/core/transport/nostr/nostr_event.dart';
import 'package:cubechat/core/transport/nostr/nostr_signer.dart';
import 'package:cubechat/features/cube_id/data/cube_id_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('leadingZeroBits counts bits, not bytes', () {
    expect(leadingZeroBits([0x00, 0x00, 0xff]), 16);
    expect(leadingZeroBits([0x00, 0x0f]), 12);
    expect(leadingZeroBits([0x80]), 0);
  });

  test('mined events meet the difficulty and carry the NIP-13 tag', () {
    final unsigned = NostrEvent(
      pubkey: 'ab' * 32,
      createdAt: 1790000000,
      kind: cubeIdKind,
      tags: const [],
      content: '{"op":"claim"}',
    );
    final mined = mineNonce(unsigned, 12);
    final digest =
        const DartSha256().hashSync(utf8.encode(mined.serializeForId())).bytes;
    expect(leadingZeroBits(digest), greaterThanOrEqualTo(12));
    expect(mined.tags.single.first, 'nonce');
    expect(mined.tags.single.last, '12');
  });

  test('a built event is signed by the identity and its id verifies', () async {
    final signer = await Secp256k1NostrSigner.deriveFromSeed(
      Uint8List.fromList(List<int>.filled(32, 7)),
    );
    final e = await buildCubeIdEvent(
      signer: signer,
      content: {'op': 'renew'},
      now: DateTime.fromMillisecondsSinceEpoch(1790000000000),
    );
    expect(e.pubkey, signer.npubHex);
    expect(e.kind, cubeIdKind);
    expect(await e.hasValidId(), isTrue);
    expect(e.sig, isNotNull);
  });
}
