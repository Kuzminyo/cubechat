import 'dart:convert';

import 'package:cubechat/features/moderation/data/ban_list_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const publicKey =
      'f8a3b6fc8195e23ce2a0f0f6c67d7a8ff1827843541c17b0a44f4a3f6c7dbb3a';
  const signature =
      'e540f985eb8139302691f82086205a2d29b44a990e03da5b0c9d84e596ab091561be8890dfed566231b36845f52be5937355ac06450e2ca9ee17864c4e761e06';
  final body = <String, dynamic>{
    'v': 1,
    'updatedAt': 1700000000,
    'identities': <String>['11' * 32, '22' * 32],
    'npubs': <String>['33' * 32],
    'fingerprints': <String>['44' * 32],
    'sig': signature,
  };

  test('verifies the exact cross-language server vector', () async {
    expect(
      canonicalBanBody(body),
      jsonEncode(<String, dynamic>{
        'v': 1,
        'updatedAt': 1700000000,
        'identities': <String>['11' * 32, '22' * 32],
        'npubs': <String>['33' * 32],
        'fingerprints': <String>['44' * 32],
      }),
    );
    final verified = await verifyBanList(body, publicKeyHex: publicKey);
    expect(verified, isNotNull);
    expect(verified!.isBannedIdentity('11' * 32), isTrue);
    expect(verified.isBannedNpub('33' * 32), isTrue);
    expect(verified.isBannedFingerprint('44' * 32), isTrue);
  });

  test('rejects tampering, missing signature, and a different key', () async {
    expect(
      await verifyBanList(
        <String, dynamic>{...body, 'updatedAt': 1700000001},
        publicKeyHex: publicKey,
      ),
      isNull,
    );
    expect(
      await verifyBanList(<String, dynamic>{...body, 'sig': ''},
          publicKeyHex: publicKey),
      isNull,
    );
    expect(await verifyBanList(body), isNull);
  });
}
