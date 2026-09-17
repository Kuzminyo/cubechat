import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/transport/frame.dart';
import 'package:cubechat/core/transport/pro_badge.dart';
import 'package:flutter_test/flutter_test.dart';

/// The badge is a *claim*, signed by the identity making it.
///
/// The signature says who is claiming, not that anybody paid: stage one keeps
/// the receipt on the device, so a modified build can assert this about
/// itself. Proving payment needs the blind-signed tokens of stage two. What
/// the signature does buy is that nobody can pin the claim on someone else.
void main() {
  late SimpleKeyPair keyPair;
  late Uint8List signPub;

  setUp(() async {
    keyPair = await Ed25519().newKeyPair();
    final pub = await keyPair.extractPublicKey();
    signPub = Uint8List.fromList(pub.bytes);
  });

  test('its frame type is free and unique in the FrameType space', () {
    expect(FrameType.proBadge.value, 0x21);
    final tags = FrameType.values.map((t) => t.value).toList();
    expect(tags.toSet().length, tags.length);
  });

  test('a signed badge round-trips and carries the claim', () async {
    final bytes = await ProBadge.signed(keyPair: keyPair, isPro: true);
    final badge = await ProBadge.verifyAndDecode(bytes);

    expect(badge.isPro, isTrue);
    expect(badge.signPubkey, signPub);
  });

  test('the claim can also say no', () async {
    final bytes = await ProBadge.signed(keyPair: keyPair, isPro: false);
    expect((await ProBadge.verifyAndDecode(bytes)).isPro, isFalse);
  });

  test('flipping the flag invalidates the signature', () async {
    // Without this, any relay on the path could promote or demote anybody.
    final bytes = await ProBadge.signed(keyPair: keyPair, isPro: false);
    final tampered = Uint8List.fromList(bytes);
    tampered[1 + 32] = 0x01;

    expect(
      () => ProBadge.verifyAndDecode(tampered),
      throwsA(isA<FormatException>()),
    );
  });

  test('a version this build does not know is refused, not guessed', () async {
    final bytes = await ProBadge.signed(keyPair: keyPair, isPro: true);
    final future = Uint8List.fromList(bytes);
    future[0] = 0x02;

    expect(
      () => ProBadge.verifyAndDecode(future),
      throwsA(isA<FormatException>()),
    );
  });

  test('a truncated badge is refused rather than read past its end', () async {
    final bytes = await ProBadge.signed(keyPair: keyPair, isPro: true);
    expect(
      () => ProBadge.verifyAndDecode(bytes.sublist(0, bytes.length - 1)),
      throwsA(isA<FormatException>()),
    );
  });
}
