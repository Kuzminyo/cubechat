import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/transport/announcement.dart';
import 'package:flutter_test/flutter_test.dart';

/// The card the Cube ID server's tests parse. Minted here so the server is
/// held to the bytes the app really signs, not to a paraphrase of the layout.
/// Regenerate with
/// `CUBE_ID_WRITE_FIXTURE=1 flutter test test/cube_id_card_fixture_test.dart`.
void main() {
  const path = 'id/test/fixtures/card.json';

  test('the Cube ID card fixture is a card this build accepts', () async {
    if (Platform.environment['CUBE_ID_WRITE_FIXTURE'] == '1') {
      final sign = await Ed25519().newKeyPair();
      final signData = await sign.extract();
      final ann = PeerAnnouncement(
        pubkey: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
        signPubkey: Uint8List.fromList((await sign.extractPublicKey()).bytes),
        signedPrekeyPub:
            Uint8List.fromList(List<int>.generate(32, (i) => 100 + i)),
        nostrPubkey: Uint8List.fromList(List<int>.generate(32, (i) => 200 - i)),
        nickname: 'Дмитро',
      );
      final bytes = await ann.sign(signData);
      File(path).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'cardB64': base64Encode(bytes),
          'nostrHex': ann.nostrPubkey
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(),
          'nickname': ann.nickname,
        }),
      );
    }
    final fixture =
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    final decoded = await PeerAnnouncement.verifyAndDecode(
      base64Decode(fixture['cardB64'] as String),
    );
    expect(decoded.nickname, fixture['nickname']);
  });
}
