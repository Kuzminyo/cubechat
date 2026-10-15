import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/crypto/signed_payload.dart';
import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Who an own-device notice is believed from.
///
/// It is sealed to this account's key and signed with it — and the receiving
/// device used to check the sender by looking it up in the *contact list*,
/// where an account never appears as a contact of itself. Every hello,
/// sign-out and goodbye between two devices of one account was dropped:
/// "the devices do not see each other" (a phone on 1151 and the computer it
/// had signed in on 1150, 2026-10-15).
void main() {
  Future<({SimpleKeyPairData pair, Uint8List pub})> signer() async {
    final pair = await Ed25519().newKeyPair();
    final data = await pair.extract();
    return (
      pair: data,
      pub: Uint8List.fromList((await pair.extractPublicKey()).bytes),
    );
  }

  final context = SignedPayload.contextBytes(
    originPubkeyHash: Uint8List(8),
    destPubkeyHash: Uint8List(8),
    msgId: Uint8List(16),
  );

  Future<Uint8List> verifiedSignerOf(
    ({SimpleKeyPairData pair, Uint8List pub}) by,
  ) async {
    final wire = await SignedPayload.wrap(
      inner: Uint8List.fromList([0xEB, 1, 2, 3]),
      context: context,
      signKeyPair: by.pair,
      senderEdPub: by.pub,
    );
    final verified = await SignedPayload.verify(
      wire: wire,
      context: context,
      expectedEdPub: null,
    );
    return verified.senderEdPub;
  }

  test('a notice signed with our own key is ours', () async {
    final me = await signer();
    expect(
      MessagingService.signedByOwnKey(await verifiedSignerOf(me), me.pub),
      isTrue,
    );
  });

  test("anybody else's signature, or none, is not", () async {
    final me = await signer();
    final stranger = await signer();
    expect(
      MessagingService.signedByOwnKey(await verifiedSignerOf(stranger), me.pub),
      isFalse,
    );
    expect(MessagingService.signedByOwnKey(null, me.pub), isFalse);
  });

  test('the receive path asks the signature, not the contact list', () {
    final source =
        File('lib/core/transport/messaging_service.dart').readAsStringSync();
    // The receive branch, not the other switches that name the type.
    final start = source.indexOf('believed from our own key only');
    expect(start, isNonNegative);
    final branch =
        source.substring(start, source.indexOf('_ownDeviceNotices.add', start));
    expect(branch, contains('signedByOwnKey(verifiedSenderEdPub'));
    expect(
      branch,
      isNot(contains('_bytesEqual(senderPub')),
      reason: 'senderPub comes from the contact list, which never holds us',
    );
  });
}
