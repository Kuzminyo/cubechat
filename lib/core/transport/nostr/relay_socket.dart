/// A single, already-connected relay link seen as a plain text duplex.
///
/// This is the narrow seam between the pure relay logic
/// ([PooledNostrRelayClient], which speaks NIP-01 JSON over it) and the actual
/// `wss://` socket ([webSocketRelaySocketFactory], backed by
/// `web_socket_channel`). Keeping the socket behind an interface lets the pool —
/// reconnection, subscription replay, event dedup, signature verification — be
/// exercised end-to-end with an in-memory fake, no real WebSocket required.
abstract class RelaySocket {
  /// Inbound relay→client text frames. Closes (optionally with an error) when
  /// the connection ends; the pool treats either as "reconnect".
  Stream<String> get messages;

  /// Send one client→relay text frame. Must not throw for an already-closed
  /// socket — the pool relies on the [messages] stream closing to notice a
  /// dead link, not on [send] surfacing it.
  void send(String data);

  /// Close the connection. Idempotent.
  Future<void> close();
}

/// Opens a [RelaySocket] to [url] (`wss://…`), completing once the connection
/// is live. Throws if the connection can't be established — the pool catches
/// that and retries with backoff.
typedef RelaySocketFactory = Future<RelaySocket> Function(String url);
