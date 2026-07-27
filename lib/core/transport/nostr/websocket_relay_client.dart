import 'dart:async';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../util/debug_log.dart';
import 'nostr_event.dart';
import 'nostr_relay_protocol.dart';
import 'nostr_transport.dart';

/// Connection state of one relay, surfaced to the settings UI.
enum RelayState { idle, connecting, connected, failed }

/// A [NostrRelayClient] over real `wss://` sockets — the thin transport wrapper
/// [NostrRelayProtocol] was written to sit under.
///
/// A pool: every configured relay gets its own socket, and the pool as a whole
/// behaves like one relay. An outbound event is published to *every* connected
/// relay (relays don't gossip, so redundancy is the only delivery guarantee we
/// get); inbound events from all relays are merged into a single stream, gated
/// on [NostrRelayProtocol.verifyInboundEvent] and de-duplicated by event id, so
/// the same event arriving from three relays surfaces once.
///
/// A public relay is untrusted: it can drop, replay, re-order, or invent
/// events. Signature verification here is the first gate; the frame inside is
/// separately end-to-end encrypted and signed, and [MessagingService]'s dedup +
/// replay window is the second. This class must therefore never be the thing
/// that decides a frame is authentic — it only decides it is *well-formed*.
class WebSocketNostrRelayClient implements NostrRelayClient {
  /// [connect] is the socket factory; production leaves it null and gets
  /// [WebSocketChannel.connect]. Tests inject an in-process channel so the
  /// whole pool (REQ, publish, verification, dedup, reconnect) runs without a
  /// network.
  WebSocketNostrRelayClient({
    required List<String> relayUrls,
    WebSocketChannel Function(Uri)? connect,
    int? sinceSeconds,
    void Function(int seconds)? onWatermark,
    Duration? publishAckTimeout,
  })  : _urls = List.unmodifiable(relayUrls),
        _connect = connect ?? WebSocketChannel.connect,
        _watermark = sinceSeconds,
        _onWatermark = onWatermark,
        _publishAckTimeout = publishAckTimeout ?? defaultPublishAckTimeout {
    for (final url in _urls) {
      _states[url] = RelayState.idle;
    }
  }

  /// Longest gap between reconnect attempts. Backoff doubles from 2 s up to
  /// this, so a relay that's down doesn't spin the radio.
  static const Duration _maxBackoff = Duration(minutes: 2);
  static const Duration _initialBackoff = Duration(seconds: 2);

  /// How far back before the watermark a REQ still asks. Relays index on the
  /// *sender's* `created_at`, so a sender whose clock trails ours can stamp an
  /// event below a watermark we already advanced past; the overlap keeps that
  /// message from being skipped. Re-downloading a few minutes of backlog is
  /// cheap and harmless — the message store dedups on wireId.
  static const Duration _sinceSlack = Duration(minutes: 10);

  /// Cap on remembered event ids for cross-relay de-duplication. Ids are 32 B
  /// of hex; a few thousand is nothing and covers any realistic burst.
  static const int _seenCapacity = 2048;

  final List<String> _urls;
  final WebSocketChannel Function(Uri) _connect;

  /// Unix seconds of the newest event we've accepted, pool-wide. Sent as the
  /// REQ `since` (minus [_sinceSlack]) so neither a reconnect nor a fresh app
  /// launch re-downloads the whole backlog a relay is holding for us. Seeded
  /// from the persisted value by the caller; every advance is reported through
  /// [_onWatermark] so it can be persisted again.
  int? _watermark;
  final void Function(int seconds)? _onWatermark;

  final _conns = <String, _RelayConnection>{};
  final _states = <String, RelayState>{};
  final _stateController = StreamController<Map<String, RelayState>>.broadcast();

  /// Inbound events, merged across relays. Created on the first [subscribe].
  StreamController<NostrEvent>? _inbound;
  String? _subscribedTo;

  /// Event ids already emitted, so N relays delivering one event yield one
  /// frame. Insertion-ordered; oldest evicted past [_seenCapacity].
  final _seenIds = <String>{};

  bool _disposed = false;

  /// Per-relay connection state, for the settings screen.
  Map<String, RelayState> get states => Map.unmodifiable(_states);

  /// Fires whenever any relay's state changes.
  Stream<Map<String, RelayState>> get stateChanges => _stateController.stream;

  /// True once at least one relay socket is up.
  bool get isConnected =>
      _states.values.any((s) => s == RelayState.connected);

  /// Open every configured relay. Returns immediately; sockets come up in the
  /// background and [stateChanges] reports progress.
  void start() {
    if (_disposed) return;
    for (final url in _urls) {
      if (_conns.containsKey(url)) continue;
      final conn = _RelayConnection(url, this);
      _conns[url] = conn;
      unawaited(conn.open());
    }
  }

  /// How long to wait for relays to answer an `EVENT` before giving up on the
  /// stragglers.
  ///
  /// Long enough that a healthy relay on a slow link still counts, short enough
  /// that a send never visibly hangs behind one that has gone quiet. Silence is
  /// reported as silence rather than as refusal — the event has most likely
  /// been stored, we just did not hear so.
  static const Duration defaultPublishAckTimeout = Duration(seconds: 5);

  final Duration _publishAckTimeout;

  /// Publishes still waiting for their `OK`, keyed by event id.
  final Map<String, _PendingPublish> _pending = {};

  @override
  Future<PublishReceipt> publish(NostrEvent event) async {
    if (_disposed) throw StateError('relay client disposed');
    final live = _conns.values.where((c) => c.isOpen).toList();
    if (live.isEmpty) {
      throw StateError('no relay connected (${_urls.length} configured)');
    }
    final id = event.id;
    final payload = NostrRelayProtocol.event(event);
    var sent = 0;
    for (final c in live) {
      if (c.send(payload)) sent++;
    }
    if (sent == 0) {
      throw StateError('every relay write failed');
    }

    // An unsigned event has no id to match an OK against; nothing downstream
    // should be publishing one, but reporting the writes beats hanging.
    if (id == null) {
      return PublishReceipt(sentTo: sent, accepted: 0, rejected: 0);
    }

    final pending = _PendingPublish(sentTo: sent);
    // A relay that answers the same id twice, or an id we are already waiting
    // on (a re-publish), resolves the earlier wait rather than colliding.
    _pending.remove(id)?.settle();
    _pending[id] = pending;

    final receipt = await pending.wait(_publishAckTimeout);
    _pending.remove(id);

    DebugLog.instance.log(
      'NOSTR',
      'published ${id.substring(0, 8)} — $receipt',
    );
    return receipt;
  }

  /// Route an `OK` back to whoever is waiting on that event id.
  void _onOk(String eventId, bool accepted, String message) {
    _pending[eventId]?.record(accepted: accepted, message: message);
  }

  @override
  Stream<NostrEvent> subscribe({required String recipientPubkeyHex}) {
    if (_disposed) return const Stream.empty();
    // One subscription per client — we only ever ask for our own mail. A second
    // call with the same pubkey re-uses the merged stream; with a different one
    // it's a bug in the caller, so fail loudly rather than silently mixing.
    if (_subscribedTo != null && _subscribedTo != recipientPubkeyHex) {
      throw StateError('already subscribed as $_subscribedTo');
    }
    _subscribedTo = recipientPubkeyHex;
    final controller = _inbound ??= StreamController<NostrEvent>.broadcast();
    for (final c in _conns.values) {
      c.sendReqIfOpen();
    }
    return controller.stream;
  }

  /// Tear down every socket and close the streams. The client is single-use —
  /// build a fresh one when the relay list changes.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Settle anything still waiting, or its caller is left on a future that
    // can never complete now the sockets are going away.
    for (final p in _pending.values) {
      p.settle();
    }
    _pending.clear();
    for (final c in _conns.values) {
      await c.close();
    }
    _conns.clear();
    await _inbound?.close();
    await _stateController.close();
  }

  // ---------------------------------------------------------------- internals

  void _setState(String url, RelayState state) {
    if (_states[url] == state) return;
    _states[url] = state;
    if (!_stateController.isClosed) _stateController.add(states);
  }

  /// Gate an inbound event and hand it to the merged stream. Everything that
  /// fails verification is dropped silently — a shared public relay carries
  /// plenty of traffic that isn't ours, and that isn't an error.
  Future<void> _onEvent(String url, NostrEvent event) async {
    final id = event.id;
    if (id == null || _seenIds.contains(id)) return;
    if (!await NostrRelayProtocol.verifyInboundEvent(event)) {
      DebugLog.instance.log('NOSTR', 'drop event from $url: failed verification');
      return;
    }
    _remember(id);
    _advanceWatermark(event.createdAt);
    final c = _inbound;
    if (c != null && !c.isClosed) c.add(event);
  }

  /// Move the watermark up to [createdAt]. Clamped to now: a relay can hand us
  /// a validly-signed event stamped years in the future (a signature says who
  /// wrote an event, not when), and letting that set `since` would blind the
  /// subscription to every real message that follows.
  void _advanceWatermark(int createdAt) {
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (createdAt > nowSeconds) return;
    if (_watermark != null && createdAt <= _watermark!) return;
    _watermark = createdAt;
    _onWatermark?.call(createdAt);
  }

  /// The `since` to put on a REQ — null until we've accepted an event, which is
  /// the first-run case where we do want the relay's full backlog.
  int? get _reqSince {
    final w = _watermark;
    if (w == null) return null;
    final since = w - _sinceSlack.inSeconds;
    return since <= 0 ? null : since;
  }

  void _remember(String id) {
    _seenIds.add(id);
    if (_seenIds.length > _seenCapacity) {
      _seenIds.remove(_seenIds.first);
    }
  }

  String? get _subscriptionTarget => _subscribedTo;
}

/// One relay socket: connect, (re)subscribe, pump messages, reconnect with
/// exponential backoff. Owned by [WebSocketNostrRelayClient].
/// One in-flight publish, collecting `OK`s until every relay has answered or
/// the deadline passes.
class _PendingPublish {
  _PendingPublish({required this.sentTo});

  final int sentTo;
  final _completer = Completer<PublishReceipt>();
  final List<String> _rejections = [];
  int _accepted = 0;
  int _rejected = 0;
  Timer? _deadline;

  void record({required bool accepted, required String message}) {
    if (_completer.isCompleted) return;
    if (accepted) {
      _accepted++;
    } else {
      _rejected++;
      if (message.isNotEmpty) _rejections.add(message);
    }
    // Everyone has spoken — no reason to sit out the rest of the timeout.
    if (_accepted + _rejected >= sentTo) settle();
  }

  Future<PublishReceipt> wait(Duration timeout) {
    _deadline = Timer(timeout, settle);
    return _completer.future;
  }

  void settle() {
    _deadline?.cancel();
    _deadline = null;
    if (_completer.isCompleted) return;
    _completer.complete(PublishReceipt(
      sentTo: sentTo,
      accepted: _accepted,
      rejected: _rejected,
      rejections: List.unmodifiable(_rejections),
    ));
  }
}

class _RelayConnection {
  _RelayConnection(this.url, this._pool);

  final String url;
  final WebSocketNostrRelayClient _pool;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retryTimer;
  Duration _backoff = WebSocketNostrRelayClient._initialBackoff;
  bool _closed = false;

  /// True only once the socket has actually completed its upgrade. Distinct
  /// from `_channel != null`, which is true the instant the factory returns and
  /// says nothing about whether anything is on the other end.
  bool _connected = false;

  final String _subId = 'cc-${Random().nextInt(1 << 32).toRadixString(16)}';

  bool get isOpen => _connected;

  /// Open the socket and wait for it to actually be up.
  ///
  /// The await is the whole point. [WebSocketChannel.connect] is lazy: it hands
  /// back a channel object immediately and does the DNS lookup and the upgrade
  /// afterwards. Treating that return as success meant every attempt logged
  /// "connected", published `RelayState.connected`, and — the part that really
  /// hurt — reset the backoff, milliseconds before the failure arrived
  /// asynchronously on the stream. `_onDown` would double a backoff that the
  /// next attempt immediately reset, so a phone with no network retried three
  /// relays every 2 s indefinitely, filling the log and holding the radio awake,
  /// while `publish` could pick a socket that had never connected.
  Future<void> open() async {
    if (_closed) return;
    _retryTimer?.cancel();
    _pool._setState(url, RelayState.connecting);
    try {
      final channel = _connectOrThrow();
      _channel = channel;
      _sub = channel.stream.listen(
        _onMessage,
        onError: (Object e) => _onDown('error: $e'),
        onDone: () => _onDown('closed by relay'),
        cancelOnError: false,
      );
      await channel.ready;
      if (_closed) return;
      // A relay accepts REQ/EVENT the moment the socket is writable; there is
      // no handshake beyond the WebSocket upgrade itself.
      _connected = true;
      _pool._setState(url, RelayState.connected);
      _backoff = WebSocketNostrRelayClient._initialBackoff;
      DebugLog.instance.log('NOSTR', 'connected $url');
      sendReqIfOpen();
    } catch (e) {
      _onDown('connect failed: $e');
    }
  }

  WebSocketChannel _connectOrThrow() => _pool._connect(Uri.parse(url));

  /// (Re)send our REQ. Called on connect and whenever the pool gains a
  /// subscription target after the socket was already up.
  void sendReqIfOpen() {
    final target = _pool._subscriptionTarget;
    if (target == null || _channel == null) return;
    send(NostrRelayProtocol.req(
      _subId,
      recipientPubkeyHex: target,
      since: _pool._reqSince,
    ));
  }

  /// Write [payload]; returns false if the socket rejected it (and schedules a
  /// reconnect), so the pool can count real successes.
  bool send(String payload) {
    final ch = _channel;
    if (ch == null) return false;
    try {
      ch.sink.add(payload);
      return true;
    } catch (e) {
      _onDown('write failed: $e');
      return false;
    }
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    final msg = NostrRelayProtocol.parse(raw);
    switch (msg) {
      case RelayEvent(:final event):
        // The watermark advances in the pool, and only for events that pass
        // verification — an unsigned event with a future timestamp must not be
        // able to push our subscription past real messages.
        unawaited(_pool._onEvent(url, event));
      case RelayOk(:final eventId, :final accepted, :final message):
        if (!accepted) {
          DebugLog.instance.log('NOSTR', '$url rejected publish: $message');
        }
        _pool._onOk(eventId, accepted, message);
      case RelayNotice(:final message):
        DebugLog.instance.log('NOSTR', '$url notice: $message');
      case RelayEose():
      case RelayUnknown():
        break;
    }
  }

  void _onDown(String reason) {
    if (_closed) return;
    // A failed connect surfaces twice — the `ready` future rejects *and* the
    // stream errors — and a dropped socket can report both error and done.
    // Without this the backoff would double per report rather than per failure,
    // and two retry timers would race.
    if (_channel == null) return;
    DebugLog.instance.log('NOSTR', '$url down ($reason) — retry in '
        '${_backoff.inSeconds}s');
    _teardownSocket();
    _pool._setState(url, RelayState.failed);
    _retryTimer?.cancel();
    _retryTimer = Timer(_backoff, () => unawaited(open()));
    final next = _backoff * 2;
    _backoff =
        next > WebSocketNostrRelayClient._maxBackoff
            ? WebSocketNostrRelayClient._maxBackoff
            : next;
  }

  void _teardownSocket() {
    _connected = false;
    unawaited(_sub?.cancel());
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  Future<void> close() async {
    _closed = true;
    _retryTimer?.cancel();
    _teardownSocket();
    _pool._setState(url, RelayState.idle);
  }
}
