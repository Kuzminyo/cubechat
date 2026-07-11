import 'dart:convert';
import 'dart:io';

import 'package:cubechat/core/nostr/nostr_event.dart';
import 'package:cubechat/core/nostr/nostr_relay.dart';
import 'package:cubechat/core/nostr/secp256k1.dart';
import 'package:flutter_test/flutter_test.dart';

/// A throwaway in-process relay: acks every EVENT with OK and, for any REQ,
/// replays the events it has seen so far, then EOSE. Enough to exercise the
/// client's publish-ack and subscribe-delivery paths without a network relay.
Future<({HttpServer server, String url})> _startFakeRelay() async {
  final server = await HttpServer.bind('localhost', 0);
  final seen = <Map<String, dynamic>>[];

  server.listen((req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.badRequest;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    ws.listen((data) {
      final msg = jsonDecode(data as String) as List;
      switch (msg[0]) {
        case 'EVENT':
          final ev = (msg[1] as Map).cast<String, dynamic>();
          seen.add(ev);
          ws.add(jsonEncode(['OK', ev['id'], true, '']));
        case 'REQ':
          final subId = msg[1] as String;
          for (final ev in seen) {
            ws.add(jsonEncode(['EVENT', subId, ev]));
          }
          ws.add(jsonEncode(['EOSE', subId]));
      }
    });
  });

  return (server: server, url: 'ws://localhost:${server.port}');
}

void main() {
  const priv =
      '0000000000000000000000000000000000000000000000000000000000000001';

  test('publish gets an OK ack and subscribe delivers the event', () async {
    final fake = await _startFakeRelay();
    addTearDown(() => fake.server.close(force: true));

    final relay = NostrRelay(fake.url);
    await relay.connect();
    addTearDown(relay.close);

    final event = NostrEvent.signed(
      privHex: priv,
      createdAt: 1700000000,
      kind: 1,
      tags: const [],
      content: 'over the relay',
    );

    final ok = await relay.publish(event);
    expect(ok, isTrue);

    final incoming = relay.events.first; // completes on the replayed EVENT
    relay.subscribe({
      'kinds': [1],
      'authors': [Secp256k1.publicKeyHex(priv)],
    });

    final got = await incoming.timeout(const Duration(seconds: 5));
    expect(got.id, event.id);
    expect(got.content, 'over the relay');
    expect(got.verify(), isTrue);
  });

  test('publish throws when not connected', () async {
    final relay = NostrRelay('ws://localhost:1');
    expect(
      () => relay.publish(NostrEvent.signed(
        privHex: priv,
        createdAt: 1,
        kind: 1,
        tags: const [],
        content: 'x',
      )),
      throwsA(isA<StateError>()),
    );
  });
}
