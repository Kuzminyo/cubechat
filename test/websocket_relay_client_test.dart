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
            ws.add(jsonEncode(['OK', ev['id'], true, '']));
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
  }) {
    return signer.sign(NostrEvent(
      pubkey: signer.npubHex,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
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
}
