import 'dart:convert';
import 'dart:typed_data';

import 'package:cubechat/core/transport/nostr/nostr_event.dart';
import 'package:cubechat/core/transport/nostr/nostr_relay_protocol.dart';
import 'package:cubechat/core/transport/nostr/nostr_signer.dart';
import 'package:cubechat/core/transport/nostr/nostr_transport.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _seed(int fill) => Uint8List.fromList(List.filled(32, fill));

NostrEvent _frameEvent(String npub) => NostrEvent(
      pubkey: npub,
      createdAt: 1700000000,
      kind: kCubechatFrameKind,
      tags: [
        ['p', 'bb' * 32],
      ],
      content: 'cc1:SGk=',
    );

void main() {
  group('client -> relay framing', () {
    test('req builds a kind + #p filter, optionally with since', () {
      final decoded =
          jsonDecode(NostrRelayProtocol.req('sub1', recipientPubkeyHex: 'aa' * 32))
              as List;
      expect(decoded[0], 'REQ');
      expect(decoded[1], 'sub1');
      final filter = decoded[2] as Map;
      expect(filter['kinds'], [kCubechatFrameKind]);
      expect(filter['#p'], ['aa' * 32]);
      expect(filter.containsKey('since'), isFalse);

      final withSinceRaw = NostrRelayProtocol.req(
        'sub1',
        recipientPubkeyHex: 'aa' * 32,
        since: 42,
      );
      final withSince = jsonDecode(withSinceRaw) as List;
      expect((withSince[2] as Map)['since'], 42);
    });

    test('event wraps the event json in an EVENT array', () {
      final ev = _frameEvent('aa' * 32);
      final decoded = jsonDecode(NostrRelayProtocol.event(ev)) as List;
      expect(decoded[0], 'EVENT');
      expect((decoded[1] as Map)['kind'], kCubechatFrameKind);
    });

    test('close builds a CLOSE array', () {
      expect(jsonDecode(NostrRelayProtocol.close('sub1')), ['CLOSE', 'sub1']);
    });
  });

  group('relay -> client parsing', () {
    test('parses an EVENT message into RelayEvent', () {
      final ev = _frameEvent('aa' * 32);
      final raw = jsonEncode(['EVENT', 'sub1', ev.toJson()]);
      final msg = NostrRelayProtocol.parse(raw);
      expect(msg, isA<RelayEvent>());
      final re = msg as RelayEvent;
      expect(re.subscriptionId, 'sub1');
      expect(re.event.kind, kCubechatFrameKind);
    });

    test('parses EOSE, OK and NOTICE', () {
      expect(
        (NostrRelayProtocol.parse(jsonEncode(['EOSE', 'sub1'])) as RelayEose)
            .subscriptionId,
        'sub1',
      );
      final ok =
          NostrRelayProtocol.parse(jsonEncode(['OK', 'ff' * 32, true, 'stored']))
              as RelayOk;
      expect(ok.accepted, isTrue);
      expect(ok.message, 'stored');
      expect(
        (NostrRelayProtocol.parse(jsonEncode(['NOTICE', 'hi'])) as RelayNotice)
            .message,
        'hi',
      );
    });

    test('malformed / unknown messages become RelayUnknown', () {
      expect(NostrRelayProtocol.parse('not json'), isA<RelayUnknown>());
      expect(NostrRelayProtocol.parse('{}'), isA<RelayUnknown>());
      expect(NostrRelayProtocol.parse(jsonEncode(['WAT', 1])), isA<RelayUnknown>());
      expect(NostrRelayProtocol.parse(jsonEncode(['EOSE'])), isA<RelayUnknown>());
    });
  });

  group('inbound verification', () {
    test('accepts a genuinely-signed cubechat event', () async {
      final signer = await Secp256k1NostrSigner.deriveFromSeed(_seed(5));
      final signed = await signer.sign(_frameEvent(signer.npubHex));
      expect(await NostrRelayProtocol.verifyInboundEvent(signed), isTrue);
    });

    test('rejects a wrong event kind', () async {
      final signer = await Secp256k1NostrSigner.deriveFromSeed(_seed(5));
      final evt = NostrEvent(
        pubkey: signer.npubHex,
        createdAt: 1700000000,
        kind: 1, // not a cubechat frame
        tags: const [],
        content: 'gm',
      );
      final signed = await signer.sign(evt);
      expect(await NostrRelayProtocol.verifyInboundEvent(signed), isFalse);
    });

    test('rejects an unsigned event', () async {
      final signer = await Secp256k1NostrSigner.deriveFromSeed(_seed(5));
      final unsigned = await _frameEvent(signer.npubHex).withId();
      expect(await NostrRelayProtocol.verifyInboundEvent(unsigned), isFalse);
    });

    test('rejects a tampered content (id no longer matches)', () async {
      final signer = await Secp256k1NostrSigner.deriveFromSeed(_seed(5));
      final signed = await signer.sign(_frameEvent(signer.npubHex));
      final tampered = signed.copyWith(content: 'cc1:EVIL=');
      expect(await NostrRelayProtocol.verifyInboundEvent(tampered), isFalse);
    });

    test('rejects a signature from a different key', () async {
      final signer = await Secp256k1NostrSigner.deriveFromSeed(_seed(5));
      final imposter = await Secp256k1NostrSigner.deriveFromSeed(_seed(6));
      // Event claims the imposter's pubkey but is signed with a mismatched id
      // path: sign under `signer` then relabel the pubkey to the imposter.
      final signed = await signer.sign(_frameEvent(imposter.npubHex));
      expect(await NostrRelayProtocol.verifyInboundEvent(signed), isFalse);
    });
  });
}
