import 'package:web_socket_channel/web_socket_channel.dart';

import 'relay_socket.dart';

/// Production [RelaySocket] over a real `wss://` connection, backed by
/// `web_socket_channel`.
///
/// A relay frame is always UTF-8 text (NIP-01 JSON arrays); any non-string
/// payload a misbehaving relay sends is coerced to its `toString()` so the
/// parser downstream can reject it as [RelayUnknown] rather than crash the
/// stream.
class WebSocketRelaySocket implements RelaySocket {
  WebSocketRelaySocket._(this._channel, this._messages);

  final WebSocketChannel _channel;
  final Stream<String> _messages;

  /// Connect to [url] and complete once the socket is ready (or throw if it
  /// never becomes ready — the caller retries with backoff).
  static Future<WebSocketRelaySocket> connect(String url) async {
    final channel = WebSocketChannel.connect(Uri.parse(url));
    await channel.ready;
    // The underlying stream is single-subscription; hand callers a broadcast
    // view so the pool can listen without racing the readiness await above.
    final messages = channel.stream
        .map((event) => event is String ? event : event.toString())
        .asBroadcastStream();
    return WebSocketRelaySocket._(channel, messages);
  }

  @override
  Stream<String> get messages => _messages;

  @override
  void send(String data) {
    try {
      _channel.sink.add(data);
    } catch (_) {
      // A write to a closing socket can throw synchronously on some platforms.
      // Swallow it: the pool notices the dead link via the closed [messages]
      // stream and reconnects, so surfacing it here would only be noise.
    }
  }

  @override
  Future<void> close() async {
    try {
      await _channel.sink.close();
    } catch (_) {
      // Already closing / closed.
    }
  }
}

/// The [RelaySocketFactory] the app wires into [PooledNostrRelayClient].
Future<RelaySocket> webSocketRelaySocketFactory(String url) =>
    WebSocketRelaySocket.connect(url);
