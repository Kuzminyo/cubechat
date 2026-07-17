import 'dart:async';
import 'dart:convert';

import 'package:cubechat/core/transport/nostr/nostr_event.dart';
import 'package:cubechat/core/transport/nostr/nostr_transport.dart';
import 'package:cubechat/core/transport/nostr/pooled_nostr_relay_client.dart';
import 'package:cubechat/core/transport/nostr/relay_socket.dart';
import 'package:flutter_test/flutter_test.dart';

/// One in-memory relay endpoint. Records what the client sent it and lets the
/// test push relay→client frames to every live socket, simulating stored-event
/// fan-out from a public relay.
class _FakeRelay {
  final List<String> sent = [];
  final List<_FakeRelaySocket> _sockets = [];
  int connectCount = 0;
  bool failNextConnect = false;

  Future<RelaySocket> connect() async {
    connectCount++;
    if (failNextConnect) {
      failNextConnect = false;
      throw StateError('relay refused connection');
    }
    final s = _FakeRelaySocket(this);
    _sockets.add(s);
    return s;
  }

  bool get isConnected => _sockets.any((s) => !s.closed);

  /// Push a relay→client frame to every live socket.
  void deliver(String raw) {
    for (final s in List.of(_sockets)) {
      s._push(raw);
    }
  }

  /// Simulate the relay dropping every connection (network blip).
  void dropAll() {
    for (final s in List.of(_sockets)) {
      s._drop();
    }
  }

  /// EVENT frames (client→relay publishes) seen so far.
  List<String> get published =>
      sent.where((s) => s.startsWith('["EVENT"')).toList();

  /// REQ frames (client→relay subscriptions) seen so far.
  List<String> get reqs => sent.where((s) => s.startsWith('["REQ"')).toList();
}

class _FakeRelaySocket implements RelaySocket {
  _FakeRelaySocket(this._relay);

  final _FakeRelay _relay;
  final StreamController<String> _ctrl = StreamController<String>();
  bool closed = false;

  @override
  Stream<String> get messages => _ctrl.stream;

  @override
  void send(String data) => _relay.sent.add(data);

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    _relay._sockets.remove(this);
    await _ctrl.close();
  }

  void _push(String raw) {
    if (!closed) _ctrl.add(raw);
  }

  void _drop() {
    if (closed) return;
    closed = true;
    _relay._sockets.remove(this);
    _ctrl.close();
  }
}

/// Let pending microtasks + short backoff timers run.
Future<void> _settle([int ms = 15]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

String _subIdOf(_FakeRelay relay) {
  final raw = relay.reqs.first;
  return (jsonDecode(raw) as List)[1] as String;
}

Future<String> _eventFrame({
  required String subId,
  required String pubkey,
  required String recipient,
  String content = 'cc1:aGVsbG8=',
}) async {
  final ev = await NostrEvent(
    pubkey: pubkey,
    createdAt: 1,
    kind: kCubechatFrameKind,
    tags: [
      [kRecipientTag, recipient],
    ],
    content: content,
  ).withId();
  return jsonEncode(['EVENT', subId, ev.toJson()]);
}

const _me = 'aa' * 32;
const _sender = 'bb' * 32;
const _other = 'cc' * 32;

void main() {
  group('PooledNostrRelayClient', () {
    late _FakeRelay r1;
    late _FakeRelay r2;
    late Map<String, _FakeRelay> byUrl;

    PooledNostrRelayClient build({
      Future<bool> Function(NostrEvent)? verify,
      List<String>? urls,
    }) =>
        PooledNostrRelayClient(
          relayUrls: urls ?? const ['wss://r1', 'wss://r2'],
          socketFactory: (url) => byUrl[url]!.connect(),
          verify: verify ?? (_) async => true,
          initialBackoff: const Duration(milliseconds: 1),
          maxBackoff: const Duration(milliseconds: 4),
        );

    setUp(() {
      r1 = _FakeRelay();
      r2 = _FakeRelay();
      byUrl = {'wss://r1': r1, 'wss://r2': r2};
    });

    test('subscribing sends a REQ to every connected relay', () async {
      final client = build();
      client.subscribe(recipientPubkeyHex: _me);
      await _settle();

      expect(r1.reqs, hasLength(1));
      expect(r2.reqs, hasLength(1));
      expect(r1.reqs.first, contains(_me));
      addTearDown(client.dispose);
    });

    test('a verified event addressed to us is delivered exactly once even when '
        'two relays both carry it', () async {
      final client = build();
      final events = <NostrEvent>[];
      client.subscribe(recipientPubkeyHex: _me).listen(events.add);
      await _settle();

      final frame = await _eventFrame(
          subId: _subIdOf(r1), pubkey: _sender, recipient: _me);
      r1.deliver(frame);
      r2.deliver(frame); // same event id from a second relay
      await _settle();

      expect(events, hasLength(1));
      expect(events.single.pubkey, _sender);
      addTearDown(client.dispose);
    });

    test('an event addressed to someone else is dropped', () async {
      final client = build();
      final events = <NostrEvent>[];
      client.subscribe(recipientPubkeyHex: _me).listen(events.add);
      await _settle();

      r1.deliver(await _eventFrame(
          subId: _subIdOf(r1), pubkey: _sender, recipient: _other));
      await _settle();

      expect(events, isEmpty);
      addTearDown(client.dispose);
    });

    test('an event that fails verification is dropped', () async {
      final client = build(verify: (e) async => e.content != 'cc1:YmFk');
      final events = <NostrEvent>[];
      client.subscribe(recipientPubkeyHex: _me).listen(events.add);
      await _settle();

      r1.deliver(await _eventFrame(
          subId: _subIdOf(r1),
          pubkey: _sender,
          recipient: _me,
          content: 'cc1:YmFk')); // "bad"
      await _settle();

      expect(events, isEmpty);
      addTearDown(client.dispose);
    });

    test('publish fans the EVENT out to every connected relay', () async {
      final client = build();
      await _settle(); // let both relays connect

      await client.publish(NostrEvent(
        pubkey: _me,
        createdAt: 1,
        kind: kCubechatFrameKind,
        tags: const [],
        content: 'cc1:aGk=',
      ));

      expect(r1.published, hasLength(1));
      expect(r2.published, hasLength(1));
      addTearDown(client.dispose);
    });

    test('a publish issued while offline is flushed when a relay reconnects',
        () async {
      final client = build(urls: const ['wss://r1']);
      await _settle();
      expect(r1.isConnected, isTrue);

      r1.dropAll(); // whole pool offline
      await _settle(2);
      expect(r1.isConnected, isFalse);

      await client.publish(NostrEvent(
        pubkey: _me,
        createdAt: 1,
        kind: kCubechatFrameKind,
        tags: const [],
        content: 'cc1:cXVldWVk',
      ));
      expect(r1.published, isEmpty); // nothing sent while down

      await _settle(); // backoff fires, relay reconnects, queue flushes
      expect(r1.isConnected, isTrue);
      expect(r1.published, hasLength(1));
      addTearDown(client.dispose);
    });

    test('the subscription is replayed after a reconnect', () async {
      final client = build(urls: const ['wss://r1']);
      client.subscribe(recipientPubkeyHex: _me);
      await _settle();
      expect(r1.reqs, hasLength(1));

      r1.dropAll();
      await _settle();

      expect(r1.connectCount, greaterThanOrEqualTo(2));
      expect(r1.reqs.length, greaterThanOrEqualTo(2)); // REQ re-sent on reconnect
      addTearDown(client.dispose);
    });

    test('a failed connection attempt is retried', () async {
      r1.failNextConnect = true;
      final client = build(urls: const ['wss://r1']);
      await _settle();

      expect(r1.connectCount, greaterThanOrEqualTo(2));
      expect(r1.isConnected, isTrue);
      addTearDown(client.dispose);
    });

    test('dispose closes sockets and the subscription stream', () async {
      final client = build();
      final stream = client.subscribe(recipientPubkeyHex: _me);
      var done = false;
      stream.listen((_) {}, onDone: () => done = true);
      await _settle();

      await client.dispose();
      await _settle();

      expect(done, isTrue);
      expect(r1.isConnected, isFalse);
      expect(r2.isConnected, isFalse);
    });
  });
}
