import 'dart:async';
import 'dart:typed_data';

import 'package:cubechat/core/transport/frame.dart';
import 'package:cubechat/core/transport/nostr/nostr_event.dart';
import 'package:cubechat/core/transport/nostr/nostr_frame_codec.dart';
import 'package:cubechat/core/transport/nostr/nostr_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory relay that routes published events to subscribers by their
/// recipient (`p`) tag — enough to exercise the full [NostrTransport] flow
/// without a WebSocket.
class _FakeRelay implements NostrRelayClient {
  final Map<String, StreamController<NostrEvent>> _byRecipient = {};
  final List<NostrEvent> published = [];

  @override
  Future<void> publish(NostrEvent event) async {
    published.add(event);
    final recipient = event.firstTagValue(kRecipientTag);
    if (recipient == null) return;
    _byRecipient[recipient]?.add(event);
  }

  @override
  Stream<NostrEvent> subscribe({required String recipientPubkeyHex}) {
    final c = _byRecipient.putIfAbsent(
      recipientPubkeyHex,
      () => StreamController<NostrEvent>.broadcast(),
    );
    return c.stream;
  }
}

/// Stand-in for the secp256k1 signer: fills in a real event id but a dummy
/// signature. The transport/relay flow doesn't depend on the signature scheme,
/// so this is enough to prove the plumbing end-to-end.
class _FakeSigner implements NostrEventSigner {
  _FakeSigner(this.npubHex);

  @override
  final String npubHex;

  @override
  Future<NostrEvent> sign(NostrEvent event) async {
    final withId = await event.withId();
    return withId.copyWith(sig: 'ff' * 64);
  }
}

Uint8List _frameBytes(String text) => Frame(
      type: FrameType.transport,
      payload: Uint8List.fromList(text.codeUnits),
    ).encode();

void main() {
  group('NostrTransport', () {
    late _FakeRelay relay;
    late NostrTransport alice;
    late NostrTransport bob;

    setUp(() {
      relay = _FakeRelay();
      alice = NostrTransport(signer: _FakeSigner('aa' * 32), relay: relay);
      bob = NostrTransport(signer: _FakeSigner('bb' * 32), relay: relay);
    });

    test('a frame sent to a peer arrives byte-for-byte on their inbound stream',
        () async {
      final payload = _frameBytes('hello over the internet');
      final received = bob.inboundFrames().first;

      await alice.sendFrame(recipientNpubHex: bob.npubHex, frameBytes: payload);

      expect(await received, payload);
    });

    test('the published event is addressed to the recipient and carries our kind',
        () async {
      await alice.sendFrame(
        recipientNpubHex: bob.npubHex,
        frameBytes: _frameBytes('x'),
      );

      expect(relay.published, hasLength(1));
      final ev = relay.published.single;
      expect(ev.pubkey, alice.npubHex);
      expect(ev.kind, kCubechatFrameKind);
      expect(ev.firstTagValue(kRecipientTag), bob.npubHex);
      expect(ev.content.startsWith(NostrFrameCodec.scheme), isTrue);
      // The signer stamped a matching id.
      expect(await ev.hasValidId(), isTrue);
    });

    test('inbound stream skips non-cubechat events on a shared relay', () async {
      final frames = <Uint8List>[];
      final sub = bob.inboundFrames().listen(frames.add);

      // Unrelated Nostr traffic addressed to bob (not a cubechat frame).
      await relay.publish(
        NostrEvent(
          pubkey: 'cc' * 32,
          createdAt: 1,
          kind: 1,
          tags: [
            [kRecipientTag, bob.npubHex],
          ],
          content: 'gm nostr',
        ),
      );
      // A real cubechat frame right after.
      final real = _frameBytes('the real one');
      await alice.sendFrame(recipientNpubHex: bob.npubHex, frameBytes: real);

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(frames, hasLength(1));
      expect(frames.single, real);
    });

    test('frames for another peer are not delivered to us', () async {
      final frames = <Uint8List>[];
      final sub = bob.inboundFrames().listen(frames.add);

      // Alice sends to herself; bob must not see it.
      await alice.sendFrame(
        recipientNpubHex: alice.npubHex,
        frameBytes: _frameBytes('mine'),
      );

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(frames, isEmpty);
    });
  });
}
