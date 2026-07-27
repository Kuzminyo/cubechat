import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/frame.dart';
import 'package:cubechat/core/transport/nostr/nostr_event.dart';
import 'package:cubechat/core/transport/nostr/nostr_frame_codec.dart';
import 'package:cubechat/core/transport/nostr/nostr_signer.dart';
import 'package:cubechat/core/transport/nostr/nostr_transport.dart';
import 'package:cubechat/core/transport/nostr/websocket_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A throwaway in-process relay speaking just enough NIP-01: ack every EVENT
/// with OK, replay stored events to any REQ, then EOSE. Lets the real
/// [WebSocketNostrRelayClient] run over a real socket without a network relay.
class _FakeRelayServer {
  _FakeRelayServer._(this._server);

  final HttpServer _server;
  final List<Map<String, dynamic>> received = [];
  final List<Map<String, dynamic>> _toReplay = [];
  final List<String> reqs = [];

  /// How this relay answers an EVENT: true for `OK true`, false for a refusal,
  /// null to say nothing at all — the relay that has gone quiet, which is the
  /// case a publish must not hang on.
  bool? okAnswer = true;

  /// What a refusal says. The default is verbatim what damus sends when it is
  /// rate-limiting, which is the refusal that was silently counted as delivery.
  String refusalMessage = 'rate-limited: you are noting too much';

  String get url => 'ws://localhost:${_server.port}';

  static Future<_FakeRelayServer> start() async {
    final server = await HttpServer.bind('localhost', 0);
    final relay = _FakeRelayServer._(server);
    server.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((data) {
        final msg = jsonDecode(data as String) as List<dynamic>;
        switch (msg[0]) {
          case 'EVENT':
            final ev = (msg[1] as Map).cast<String, dynamic>();
            relay.received.add(ev);
            final answer = relay.okAnswer;
            if (answer != null) {
              ws.add(jsonEncode([
                'OK',
                ev['id'],
                answer,
                answer ? '' : relay.refusalMessage,
              ]));
            }
          case 'REQ':
            final subId = msg[1] as String;
            relay.reqs.add(data);
            for (final ev in relay._toReplay) {
              ws.add(jsonEncode(['EVENT', subId, ev]));
            }
            ws.add(jsonEncode(['EOSE', subId]));
        }
      });
    });
    return relay;
  }

  /// Queue an event the relay hands to the next subscriber.
  void willDeliver(NostrEvent event) => _toReplay.add(event.toJson());

  Future<void> stop() => _server.close(force: true);
}

/// Wait for [check] to hold, polling the event loop — the client connects,
/// subscribes and receives asynchronously across a real socket.
Future<void> _until(bool Function() check, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!check()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for ${reason ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  // A deterministic identity seed → a real, verifiable BIP-340 signer, so
  // inbound events pass the client's signature gate the same way they will in
  // production.
  final seed = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
  late Secp256k1NostrSigner signer;

  setUpAll(() async {
    signer = await Secp256k1NostrSigner.deriveFromSeed(seed);
  });

  Future<NostrEvent> signedFrameEvent(
    Uint8List frameBytes, {
    required String recipientNpubHex,
    int? createdAt,
  }) {
    return signer.sign(NostrEvent(
      pubkey: signer.npubHex,
      createdAt: createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: kCubechatFrameKind,
      tags: [
        [kRecipientTag, recipientNpubHex],
      ],
      content: NostrFrameCodec.encodeContent(frameBytes),
    ));
  }

  final frame = Frame(
    type: FrameType.transport,
    payload: Uint8List.fromList(List<int>.generate(40, (i) => i)),
  ).encode();

  group('publish acceptance', () {
    // Short deadline so the silent-relay case doesn't sit out a real timeout.
    const ackTimeout = Duration(milliseconds: 300);

    test('an accepted event reports acceptance', () async {
      final relay = await _FakeRelayServer.start();
      addTearDown(relay.stop);
      final client = WebSocketNostrRelayClient(
        relayUrls: [relay.url],
        publishAckTimeout: ackTimeout,
      );
      addTearDown(client.dispose);
      client.start();
      await _until(() => client.isConnected, reason: 'connect');

      final receipt = await NostrTransport(signer: signer, relay: client)
          .sendFrame(recipientNpubHex: 'ab' * 32, frameBytes: frame);

      expect(receipt.isAccepted, isTrue);
      expect(receipt.accepted, 1);
      expect(receipt.rejected, 0);
      expect(receipt.silent, 0);
    });

    test('a refusal is reported as refused, not as delivery', () async {
      // This is the bug the receipt exists for: damus answers a burst with
      // "rate-limited: you are noting too much" and drops the event, and the
      // old publish() returned as though it had been sent.
      final relay = await _FakeRelayServer.start();
      addTearDown(relay.stop);
      relay.okAnswer = false;

      final client = WebSocketNostrRelayClient(
        relayUrls: [relay.url],
        publishAckTimeout: ackTimeout,
      );
      addTearDown(client.dispose);
      client.start();
      await _until(() => client.isConnected, reason: 'connect');

      final receipt = await NostrTransport(signer: signer, relay: client)
          .sendFrame(recipientNpubHex: 'ab' * 32, frameBytes: frame);

      expect(receipt.isAccepted, isFalse);
      expect(receipt.isRefused, isTrue);
      expect(receipt.rejected, 1);
      expect(receipt.rejections.single, contains('rate-limited'));
    });

    test('a relay that never answers resolves as silent, not as a hang',
        () async {
      final relay = await _FakeRelayServer.start();
      addTearDown(relay.stop);
      relay.okAnswer = null; // accepts the write, says nothing

      final client = WebSocketNostrRelayClient(
        relayUrls: [relay.url],
        publishAckTimeout: ackTimeout,
      );
      addTearDown(client.dispose);
      client.start();
      await _until(() => client.isConnected, reason: 'connect');

      final receipt = await NostrTransport(signer: signer, relay: client)
          .sendFrame(recipientNpubHex: 'ab' * 32, frameBytes: frame)
          .timeout(const Duration(seconds: 3));

      expect(receipt.silent, 1);
      expect(receipt.isRefused, isFalse,
          reason: 'silence is not a refusal — the event was probably stored');
      expect(receipt.isAccepted, isFalse);
    });

    test('one relay accepting is enough, even when another refuses', () async {
      final good = await _FakeRelayServer.start();
      final bad = await _FakeRelayServer.start();
      addTearDown(good.stop);
      addTearDown(bad.stop);
      bad.okAnswer = false;

      final client = WebSocketNostrRelayClient(
        relayUrls: [good.url, bad.url],
        publishAckTimeout: ackTimeout,
      );
      addTearDown(client.dispose);
      client.start();
      await _until(() => client.isConnected, reason: 'connect');
      // Both sockets have to be up, or this measures a one-relay pool.
      await _until(() => client.states.values.where((s) => s == RelayState.connected).length == 2,
          reason: 'both relays connected');

      final receipt = await NostrTransport(signer: signer, relay: client)
          .sendFrame(recipientNpubHex: 'ab' * 32, frameBytes: frame);

      expect(receipt.accepted, 1);
      expect(receipt.rejected, 1);
      expect(receipt.isAccepted, isTrue,
          reason: 'the recipient reads every relay in their own list');
      expect(receipt.isRefused, isFalse);
    });
  });

  test('publishes a signed frame event the relay receives', () async {
    final relay = await _FakeRelayServer.start();
    addTearDown(relay.stop);

    final client = WebSocketNostrRelayClient(relayUrls: [relay.url]);
    addTearDown(client.dispose);
    client.start();
    await _until(() => client.isConnected, reason: 'connect');

    final transport = NostrTransport(signer: signer, relay: client);
    await transport.sendFrame(
      recipientNpubHex: 'ab' * 32,
      frameBytes: frame,
    );

    await _until(() => relay.received.isNotEmpty, reason: 'EVENT at relay');
    final ev = relay.received.single;
    expect(ev['kind'], kCubechatFrameKind);
    expect(ev['pubkey'], signer.npubHex);
    expect((ev['tags'] as List).first, [kRecipientTag, 'ab' * 32]);
    // The relay only ever sees the opaque, already-encrypted cubechat frame.
    expect(
      NostrFrameCodec.decodeContent(ev['content'] as String),
      equals(frame),
    );
  });

  test('subscribes for our own mail and yields the frame bytes back', () async {
    final relay = await _FakeRelayServer.start();
    addTearDown(relay.stop);
    relay.willDeliver(
      await signedFrameEvent(frame, recipientNpubHex: signer.npubHex),
    );

    final client = WebSocketNostrRelayClient(relayUrls: [relay.url]);
    addTearDown(client.dispose);
    final transport = NostrTransport(signer: signer, relay: client);
    final frames = <Uint8List>[];
    transport.inboundFrames().listen(frames.add);
    client.start();

    await _until(() => frames.isNotEmpty, reason: 'inbound frame');
    expect(frames.single, equals(frame));

    // The REQ must filter on our kind + our pubkey, or a shared relay would
    // firehose unrelated traffic at us.
    final req = jsonDecode(relay.reqs.single) as List<dynamic>;
    final filter = (req[2] as Map).cast<String, dynamic>();
    expect(filter['kinds'], [kCubechatFrameKind]);
    expect(filter['#p'], [signer.npubHex]);
  });

  test('the same event from two relays surfaces once', () async {
    final a = await _FakeRelayServer.start();
    final b = await _FakeRelayServer.start();
    addTearDown(a.stop);
    addTearDown(b.stop);
    final event =
        await signedFrameEvent(frame, recipientNpubHex: signer.npubHex);
    a.willDeliver(event);
    b.willDeliver(event);

    final client = WebSocketNostrRelayClient(relayUrls: [a.url, b.url]);
    addTearDown(client.dispose);
    final transport = NostrTransport(signer: signer, relay: client);
    final frames = <Uint8List>[];
    transport.inboundFrames().listen(frames.add);
    client.start();

    await _until(() => frames.isNotEmpty, reason: 'inbound frame');
    // Give the second relay's copy time to arrive and be dropped.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(frames, hasLength(1));
  });

  test('drops an event whose signature does not verify', () async {
    final relay = await _FakeRelayServer.start();
    addTearDown(relay.stop);
    final good =
        await signedFrameEvent(frame, recipientNpubHex: signer.npubHex);
    // A public relay is untrusted: it can hand back an event that claims our
    // peer's pubkey but was never signed by them.
    relay.willDeliver(good.copyWith(sig: 'ff' * 64));

    final client = WebSocketNostrRelayClient(relayUrls: [relay.url]);
    addTearDown(client.dispose);
    final transport = NostrTransport(signer: signer, relay: client);
    final frames = <Uint8List>[];
    transport.inboundFrames().listen(frames.add);
    client.start();

    await _until(() => relay.reqs.isNotEmpty, reason: 'REQ sent');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(frames, isEmpty);
  });

  // Without a persisted watermark, every launch asked each relay for its whole
  // stored backlog — which is how testers ended up with their entire
  // internet-delivered history re-delivered (and re-shown) on each restart.
  group('subscription watermark', () {
    /// The `since` on the single REQ [relay] has received, or null if absent.
    int? sinceOf(_FakeRelayServer relay) {
      final req = jsonDecode(relay.reqs.single) as List<dynamic>;
      return ((req[2] as Map).cast<String, dynamic>())['since'] as int?;
    }

    test('a seeded watermark resumes the REQ instead of re-asking for all',
        () async {
      final relay = await _FakeRelayServer.start();
      addTearDown(relay.stop);

      const stored = 1770000000; // whatever the last launch persisted
      final client = WebSocketNostrRelayClient(
        relayUrls: [relay.url],
        sinceSeconds: stored,
      );
      addTearDown(client.dispose);
      final transport = NostrTransport(signer: signer, relay: client);
      transport.inboundFrames().listen((_) {});
      client.start();

      await _until(() => relay.reqs.isNotEmpty, reason: 'REQ sent');
      // Slack below the watermark: relays index on the sender's clock, so a
      // sender running slightly behind us must not fall into the gap.
      expect(sinceOf(relay), stored - 600);
    });

    test('first run asks for everything the relay holds', () async {
      final relay = await _FakeRelayServer.start();
      addTearDown(relay.stop);

      final client = WebSocketNostrRelayClient(relayUrls: [relay.url]);
      addTearDown(client.dispose);
      final transport = NostrTransport(signer: signer, relay: client);
      transport.inboundFrames().listen((_) {});
      client.start();

      await _until(() => relay.reqs.isNotEmpty, reason: 'REQ sent');
      expect(sinceOf(relay), isNull);
    });

    test('an accepted event reports the new watermark for persisting',
        () async {
      final relay = await _FakeRelayServer.start();
      addTearDown(relay.stop);
      final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      relay.willDeliver(await signedFrameEvent(
        frame,
        recipientNpubHex: signer.npubHex,
        createdAt: createdAt,
      ));

      final marks = <int>[];
      final client = WebSocketNostrRelayClient(
        relayUrls: [relay.url],
        onWatermark: marks.add,
      );
      addTearDown(client.dispose);
      final transport = NostrTransport(signer: signer, relay: client);
      final frames = <Uint8List>[];
      transport.inboundFrames().listen(frames.add);
      client.start();

      await _until(() => frames.isNotEmpty, reason: 'inbound frame');
      expect(marks, [createdAt]);
    });

    test('a future-dated event cannot push the watermark past real mail',
        () async {
      final relay = await _FakeRelayServer.start();
      addTearDown(relay.stop);
      // Validly signed, but stamped a year out: a signature says who wrote an
      // event, not when. Honouring it as `since` would blind the subscription.
      relay.willDeliver(await signedFrameEvent(
        frame,
        recipientNpubHex: signer.npubHex,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 31536000,
      ));

      final marks = <int>[];
      final client = WebSocketNostrRelayClient(
        relayUrls: [relay.url],
        onWatermark: marks.add,
      );
      addTearDown(client.dispose);
      final transport = NostrTransport(signer: signer, relay: client);
      final frames = <Uint8List>[];
      transport.inboundFrames().listen(frames.add);
      client.start();

      // The frame is still delivered (the replay window upstream judges its
      // age) — only the watermark refuses to move.
      await _until(() => frames.isNotEmpty, reason: 'inbound frame');
      expect(marks, isEmpty);
    });
  });

  test('publish throws when no relay is connected', () async {
    final client = WebSocketNostrRelayClient(relayUrls: const []);
    addTearDown(client.dispose);
    client.start();

    final transport = NostrTransport(signer: signer, relay: client);
    // MessagingService relies on this throwing: it's what makes an undeliverable
    // message fall through to store-and-forward instead of being lost.
    await expectLater(
      transport.sendFrame(recipientNpubHex: 'ab' * 32, frameBytes: frame),
      throwsA(isA<StateError>()),
    );
  });

  group('a relay that never answers', () {
    // Nothing is listening here, so the connect fails the way a phone with no
    // network does: asynchronously, after WebSocketChannel.connect has already
    // handed back a channel.
    const deadUrl = 'ws://localhost:9';

    test('is never reported as connected', () async {
      final client = WebSocketNostrRelayClient(relayUrls: const [deadUrl]);
      addTearDown(client.dispose);
      client.start();

      await _until(
        () => client.states[deadUrl] == RelayState.failed,
        reason: 'the failure to surface',
      );
      expect(
        client.isConnected,
        isFalse,
        reason: 'claiming connected before the socket is up let publish pick a '
            'dead relay, and reset the backoff on every attempt',
      );
    });

    test('backs off instead of retrying forever at the same interval',
        () async {
      final client = WebSocketNostrRelayClient(relayUrls: const [deadUrl]);
      addTearDown(client.dispose);

      var attempts = 0;
      final sub = client.stateChanges.listen((states) {
        if (states[deadUrl] == RelayState.connecting) attempts++;
      });
      addTearDown(sub.cancel);

      client.start();
      // First retry is 2s, so within three seconds a working backoff allows the
      // initial attempt plus at most one retry. The bug reset the backoff on
      // every attempt, which pinned it at 2s forever — over a long run that is
      // a phone holding its radio awake for a network that is not there.
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(attempts, lessThanOrEqualTo(2));
    });
  });

  test('publish ignores a socket that has not finished connecting', () async {
    final relay = await _FakeRelayServer.start();
    addTearDown(relay.stop);

    final client = WebSocketNostrRelayClient(relayUrls: [relay.url]);
    addTearDown(client.dispose);
    client.start();

    // Synchronously after start() the channel object exists but the upgrade has
    // not happened. Publishing here used to write into it and report success.
    expect(client.isConnected, isFalse);

    await _until(() => client.isConnected, reason: 'connect');
    expect(client.states[relay.url], RelayState.connected);
  });
}
