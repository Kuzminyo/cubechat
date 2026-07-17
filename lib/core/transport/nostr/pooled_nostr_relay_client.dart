import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'nostr_event.dart';
import 'nostr_relay_protocol.dart';
import 'nostr_transport.dart';
import 'relay_socket.dart';

/// A small, sensible default set of well-known public Nostr relays. The
/// off-mesh fallback is best-effort: publishing to several independent relays
/// makes it likely at least one is reachable and still holds the event when the
/// recipient next comes online.
const List<String> kDefaultNostrRelays = <String>[
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.nostr.band',
  'wss://nostr.mom',
];

/// A [NostrRelayClient] that fans a subscription and every publish across a
/// pool of relay sockets, reconnecting each with exponential backoff and
/// gating every inbound event on cubechat's [verify] check before it reaches a
/// subscriber.
///
/// The socket itself is injected as a [RelaySocketFactory] so the whole pool —
/// reconnection, subscription replay on reconnect, cross-relay event dedup, and
/// signature verification — is unit-testable against an in-memory fake with no
/// real WebSocket. Production wires in `webSocketRelaySocketFactory`.
///
/// Reliability model: this is a *fallback* pipe, deliberately fire-and-forget.
///   * A publish issued while at least one relay is connected goes out
///     immediately; issued while the whole pool is down it is queued (bounded,
///     TTL'd to the replay window) and flushed the moment a relay reconnects,
///     so a send made just before connectivity returns isn't silently dropped.
///   * Inbound events are deduplicated by event id across relays and reconnects
///     so the same frame arriving from three relays is delivered once.
class PooledNostrRelayClient implements NostrRelayClient {
  PooledNostrRelayClient({
    required List<String> relayUrls,
    required RelaySocketFactory socketFactory,
    Future<bool> Function(NostrEvent)? verify,
    Duration initialBackoff = const Duration(seconds: 1),
    Duration maxBackoff = const Duration(seconds: 30),
    int maxPendingPublishes = 128,
    Duration pendingPublishTtl = const Duration(hours: 1),
    int seenEventCapacity = 4096,
    Random? random,
  })  : _socketFactory = socketFactory,
        _verify = verify ?? NostrRelayProtocol.verifyInboundEvent,
        _initialBackoff = initialBackoff,
        _maxBackoff = maxBackoff,
        _maxPendingPublishes = maxPendingPublishes,
        _pendingPublishTtl = pendingPublishTtl,
        _seenEventCapacity = seenEventCapacity,
        _random = random ?? Random() {
    for (final url in relayUrls) {
      final conn = _RelayConn(url, this);
      _conns.add(conn);
      conn.start();
    }
  }

  final RelaySocketFactory _socketFactory;
  final Future<bool> Function(NostrEvent) _verify;
  final Duration _initialBackoff;
  final Duration _maxBackoff;
  final int _maxPendingPublishes;
  final Duration _pendingPublishTtl;
  final int _seenEventCapacity;
  final Random _random;

  final List<_RelayConn> _conns = [];
  final Map<String, _Subscription> _subs = {};

  /// Recently-seen inbound event ids (bounded FIFO) so a frame relayed by
  /// several relays is emitted to subscribers exactly once.
  final LinkedHashSet<String> _seenEventIds = LinkedHashSet<String>();

  /// EVENT frames published while the pool was fully offline, awaiting the
  /// first reconnect. Bounded + TTL'd so a long outage can't grow it without
  /// limit.
  final Queue<_PendingPublish> _pendingPublishes = Queue<_PendingPublish>();

  var _subCounter = 0;
  var _disposed = false;

  /// How many relays in the pool currently hold a live connection.
  int get connectedRelayCount => _conns.where((c) => c.isConnected).length;

  @override
  Future<void> publish(NostrEvent event) async {
    if (_disposed) return;
    final frame = NostrRelayProtocol.event(event);
    var sentToAny = false;
    for (final c in _conns) {
      if (c.isConnected) {
        c.send(frame);
        sentToAny = true;
      }
    }
    if (!sentToAny) {
      _enqueuePublish(frame);
    }
  }

  @override
  Stream<NostrEvent> subscribe({required String recipientPubkeyHex}) {
    final subId = 'cc-${_subCounter++}';
    final sub = _Subscription(
      id: subId,
      recipientPubkeyHex: recipientPubkeyHex,
      controller: StreamController<NostrEvent>.broadcast(),
    );
    _subs[subId] = sub;
    final req = NostrRelayProtocol.req(subId,
        recipientPubkeyHex: recipientPubkeyHex);
    for (final c in _conns) {
      if (c.isConnected) c.send(req);
    }
    return sub.controller.stream;
  }

  /// Tear the pool down: close every socket and every subscription stream.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final c in _conns) {
      await c.dispose();
    }
    for (final s in _subs.values) {
      await s.controller.close();
    }
    _subs.clear();
    _pendingPublishes.clear();
  }

  // ---------------------------- internal API ----------------------------
  // Called by _RelayConn.

  /// Backoff delay for a relay's [attempt]th consecutive failure (0-based),
  /// capped at [_maxBackoff] with up to ±25% jitter so a fleet of relays
  /// doesn't reconnect in lockstep.
  Duration _backoffFor(int attempt) {
    final capMs = _maxBackoff.inMilliseconds;
    final baseMs = _initialBackoff.inMilliseconds * (1 << attempt.clamp(0, 20));
    final boundedMs = baseMs.clamp(0, capMs);
    final jitter = (boundedMs * 0.25 * (_random.nextDouble() * 2 - 1)).round();
    return Duration(milliseconds: (boundedMs + jitter).clamp(0, capMs).toInt());
  }

  /// Everything a freshly-(re)connected relay must replay: all active REQs,
  /// then any publishes buffered while it (and the rest of the pool) was down.
  void _onRelayConnected(_RelayConn conn) {
    for (final sub in _subs.values) {
      conn.send(NostrRelayProtocol.req(sub.id,
          recipientPubkeyHex: sub.recipientPubkeyHex));
    }
    _flushPendingPublishes(conn);
  }

  Future<void> _onRelayMessage(String raw) async {
    if (_disposed) return;
    final msg = NostrRelayProtocol.parse(raw);
    if (msg is! RelayEvent) return; // EOSE / OK / NOTICE / unknown: nothing to do
    final sub = _subs[msg.subscriptionId];
    if (sub == null || sub.controller.isClosed) return;

    final event = msg.event;
    final id = event.id;
    if (id == null || _seenEventIds.contains(id)) return;

    // A public relay is untrusted: re-check the signature and that the event is
    // actually a cubechat frame addressed to this subscription, never relying
    // on the relay having honoured the REQ filter.
    if (event.firstTagValue(kRecipientTag) != sub.recipientPubkeyHex) return;
    if (!await _verify(event)) return;

    // Re-check liveness across the await, then record + emit once.
    if (_disposed || sub.controller.isClosed) return;
    if (!_markSeen(id)) return;
    sub.controller.add(event);
  }

  /// Records [id] as seen; returns false if it was already present (a race
  /// where two relays delivered the same event concurrently).
  bool _markSeen(String id) {
    if (!_seenEventIds.add(id)) return false;
    while (_seenEventIds.length > _seenEventCapacity) {
      _seenEventIds.remove(_seenEventIds.first);
    }
    return true;
  }

  void _enqueuePublish(String frame) {
    _pendingPublishes.add(_PendingPublish(frame, DateTime.now()));
    while (_pendingPublishes.length > _maxPendingPublishes) {
      _pendingPublishes.removeFirst();
    }
  }

  void _flushPendingPublishes(_RelayConn conn) {
    if (_pendingPublishes.isEmpty) return;
    final cutoff = DateTime.now().subtract(_pendingPublishTtl);
    // Drop stale entries, then replay the rest to this relay. They stay queued
    // for other relays that may still be reconnecting (dedup on the receiver
    // side by event id makes the redundant delivery harmless).
    _pendingPublishes.removeWhere((p) => p.queuedAt.isBefore(cutoff));
    for (final p in _pendingPublishes) {
      conn.send(p.frame);
    }
  }
}

/// One relay's connection lifecycle: connect, replay, listen, reconnect.
class _RelayConn {
  _RelayConn(this.url, this._pool);

  final String url;
  final PooledNostrRelayClient _pool;

  RelaySocket? _socket;
  StreamSubscription<String>? _msgSub;
  Timer? _reconnectTimer;
  int _attempt = 0;
  var _disposed = false;

  bool get isConnected => _socket != null;

  void start() {
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (_disposed) return;
    try {
      final socket = await _pool._socketFactory(url);
      if (_disposed) {
        await socket.close();
        return;
      }
      _socket = socket;
      _attempt = 0;
      _msgSub = socket.messages.listen(
        (raw) => unawaited(_pool._onRelayMessage(raw)),
        onError: (_) => _onDisconnected(),
        onDone: _onDisconnected,
        cancelOnError: true,
      );
      _pool._onRelayConnected(this);
    } catch (_) {
      _onDisconnected();
    }
  }

  void _onDisconnected() {
    if (_disposed) return;
    _teardownSocket();
    final delay = _pool._backoffFor(_attempt);
    _attempt++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () => unawaited(_connect()));
  }

  void send(String data) => _socket?.send(data);

  void _teardownSocket() {
    _msgSub?.cancel();
    _msgSub = null;
    final s = _socket;
    _socket = null;
    if (s != null) unawaited(s.close());
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _msgSub?.cancel();
    _msgSub = null;
    final s = _socket;
    _socket = null;
    if (s != null) await s.close();
  }
}

/// A caller subscription: its REQ id, the recipient it filters on, and the
/// broadcast stream frames are pushed to.
class _Subscription {
  _Subscription({
    required this.id,
    required this.recipientPubkeyHex,
    required this.controller,
  });

  final String id;
  final String recipientPubkeyHex;
  final StreamController<NostrEvent> controller;
}

/// A publish buffered while the whole pool was offline.
class _PendingPublish {
  _PendingPublish(this.frame, this.queuedAt);
  final String frame;
  final DateTime queuedAt;
}
