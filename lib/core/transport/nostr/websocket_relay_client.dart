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
  })  : _urls = List.unmodifiable(relayUrls),
        _connect = connect ?? WebSocketChannel.connect {
    for (final url in _urls) {
      _states[url] = RelayState.idle;
    }
  }

  /// Longest gap between reconnect attempts. Backoff doubles from 2 s up to
  /// this, so a relay that's down doesn't spin the radio.
  static const Duration _maxBackoff = Duration(minutes: 2);
  static const Duration _initialBackoff = Duration(seconds: 2);

  /// Cap on remembered event ids for cross-relay de-duplication. Ids are 32 B
  /// of hex; a few thousand is nothing and covers any realistic burst.
  static const int _seenCapacity = 2048;

  final List<String> _urls;
  final WebSocketChannel Function(Uri) _connect;

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
      conn.open();
    }
  }

  @override
  Future<void> publish(NostrEvent event) async {
    if (_disposed) throw StateError('relay client disposed');
    final live = _conns.values.where((c) => c.isOpen).toList();
    if (live.isEmpty) {
      throw StateError('no relay connected (${_urls.length} configured)');
    }
    final payload = NostrRelayProtocol.event(event);
    var sent = 0;
    for (final c in live) {
      if (c.send(payload)) sent++;
    }
    if (sent == 0) {
      throw StateError('every relay write failed');
    }
    DebugLog.instance
        .log('NOSTR', 'published ${event.id?.substring(0, 8)} to $sent relay(s)');
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
    final c = _inbound;
    if (c != null && !c.isClosed) c.add(event);
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
class _RelayConnection {
  _RelayConnection(this.url, this._pool);

  final String url;
  final WebSocketNostrRelayClient _pool;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retryTimer;
  Duration _backoff = WebSocketNostrRelayClient._initialBackoff;
  bool _closed = false;

  /// Unix seconds of the newest event we've accepted, replayed as the REQ
  /// `since` on reconnect so we don't re-download the whole backlog (and don't
  /// miss what landed while we were away).
  int? _since;

  final String _subId = 'cc-${Random().nextInt(1 << 32).toRadixString(16)}';

  bool get isOpen => _channel != null;

  void open() {
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
      // A relay accepts REQ/EVENT the moment the socket is writable; there is
      // no handshake beyond the WebSocket upgrade itself.
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
      since: _since,
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
        final createdAt = event.createdAt;
        if (_since == null || createdAt > _since!) _since = createdAt;
        unawaited(_pool._onEvent(url, event));
      case RelayOk(:final accepted, :final message):
        if (!accepted) {
          DebugLog.instance.log('NOSTR', '$url rejected publish: $message');
        }
      case RelayNotice(:final message):
        DebugLog.instance.log('NOSTR', '$url notice: $message');
      case RelayEose():
      case RelayUnknown():
        break;
    }
  }

  void _onDown(String reason) {
    if (_closed) return;
    DebugLog.instance.log('NOSTR', '$url down ($reason) — retry in '
        '${_backoff.inSeconds}s');
    _teardownSocket();
    _pool._setState(url, RelayState.failed);
    _retryTimer?.cancel();
    _retryTimer = Timer(_backoff, open);
    final next = _backoff * 2;
    _backoff =
        next > WebSocketNostrRelayClient._maxBackoff
            ? WebSocketNostrRelayClient._maxBackoff
            : next;
  }

  void _teardownSocket() {
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
