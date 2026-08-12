import 'package:cubechat/core/transport/shared_contact.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pubkey =
      'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';

  test('an ordinary share still encodes as it always did', () {
    // The two extra fields are omitted entirely when absent, so a build that
    // knows nothing about invitations sees the payload it has always seen.
    final wire =
        const SharedContact(pubkeyHex: pubkey, displayName: 'Kuz').encode();
    final back = SharedContact.tryParse(wire)!;

    expect(back.pubkeyHex, pubkey);
    expect(back.displayName, 'Kuz');
    expect(back.isInvitation, isFalse);
    expect(back.card, isNull);
  });

  test('an invitation carries who it is for and the card to act on', () {
    final wire = const SharedContact(
      pubkeyHex: pubkey,
      displayName: 'Kuz',
      invitedMemberId: '8E39F8032E571A26',
      card: 'cubechat:card:v1:whatever',
    ).encode();
    final back = SharedContact.tryParse(wire)!;

    expect(back.isInvitation, isTrue);
    // Folded to lower case, because the fingerprint it is compared against is.
    expect(back.invitedMemberId, '8e39f8032e571a26');
    expect(back.card, 'cubechat:card:v1:whatever');
  });

  test('a malformed recipient is dropped rather than believed', () {
    // Not sixteen hex characters: something else's field, or a broken sender.
    // The card still reads as a plain share — the safe half of the payload.
    final wire = const SharedContact(
      pubkeyHex: pubkey,
      displayName: 'Kuz',
      invitedMemberId: 'not-a-fingerprint',
    ).encode();
    final back = SharedContact.tryParse(wire)!;

    expect(back.invitedMemberId, isNull);
    expect(back.isInvitation, isFalse);
    expect(back.displayName, 'Kuz');
  });
}
