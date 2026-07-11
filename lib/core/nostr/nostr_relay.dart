import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'nostr_event.dart';

/// A single Nostr relay connection speaking the NIP-01 client protocol over a
/// WebSocket.
///
/// Client → relay: `["EVENT", event]` to publish, `["REQ", subId, filter]` to
/// subscribe, `["CLOSE", subId]` to stop.
/// Relay → client: `["EVENT", subId, event]` for matches, `["OK", id, bool,
/// msg]` for publish acks, `["EOSE", subId]` end-of-stored-events, `["NOTICE",
/// msg]` / `["CLOSED", ...]` informational.
///
/// This is the raw transport only — no relay-pool, retry, or NIP-17 wrapping
/// (that lives above it). One connection per instance; call [close] when done.
class NostrRelay {
  NostrRelay(this.url);

  final String url;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final _events = StreamController<NostrEvent>.broadcast();
  final Map<String, Completer<bool>> _acks = {};
  int _subCounter = 0;

  /// Events pushed by the relay for our subscriptions.
  Stream<NostrEvent> get events => _events.stream;

  bool get isConnected => _channel != null;

  /// Open the connection and wait until it's ready. Throws on failure.
  Future<void> connect() async {
    final channel = WebSocketChannel.connect(Uri.parse(url));
    await channel.ready;
    _channel = channel;
    _sub = channel.stream.listen(
      _onMessage,
      onDone: _onClosed,
      onError: (_) => _onClosed(),
    );
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! List || decoded.isEmpty) return;

    switch (decoded[0]) {
      case 'EVENT':
        // ["EVENT", subId, event]
        if (decoded.length >= 3 && decoded[2] is Map) {
          try {
            _events.add(NostrEvent.fromJson(
                (decoded[2] as Map).cast<String, dynamic>()));
          } catch (_) {/* malformed event — skip */}
        }
      case 'OK':
        // ["OK", eventId, accepted, message]
        final id = decoded.length > 1 ? decoded[1] as String? : null;
        final accepted = decoded.length > 2 && decoded[2] == true;
        if (id != null) _acks.remove(id)?.complete(accepted);
      // EOSE / NOTICE / CLOSED: nothing to do at this layer.
    }
  }

  void _onClosed() {
    _channel = null;
    for (final c in _acks.values) {
      if (!c.isCompleted) c.complete(false);
    }
    _acks.clear();
  }

  /// Publish [event] and return the relay's OK ack (false on rejection or
  /// timeout).
  Future<bool> publish(
    NostrEvent event, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    final channel = _channel;
    if (channel == null) throw StateError('relay not connected');
    final completer = Completer<bool>();
    _acks[event.id] = completer;
    channel.sink.add(jsonEncode(['EVENT', event.toJson()]));
    return completer.future.timeout(timeout, onTimeout: () {
      _acks.remove(event.id);
      return false;
    });
  }

  /// Subscribe with a NIP-01 [filter] (e.g. `{'kinds': [1059], '#p': [myPub]}`).
  /// Matching events arrive on [events]. Returns the subscription id.
  String subscribe(Map<String, dynamic> filter) {
    final channel = _channel;
    if (channel == null) throw StateError('relay not connected');
    final subId = 'cube${_subCounter++}';
    channel.sink.add(jsonEncode(['REQ', subId, filter]));
    return subId;
  }

  void unsubscribe(String subId) {
    _channel?.sink.add(jsonEncode(['CLOSE', subId]));
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
    _onClosed();
    await _events.close();
  }
}
